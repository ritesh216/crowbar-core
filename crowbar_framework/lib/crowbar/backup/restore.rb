#
# Copyright 2015, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Crowbar
  class Backup
    class Restore
      attr_accessor :backup, :version

      def initialize(backup)
        @backup = backup
        @data = @backup.data
        @version = @backup.version
        @status = {}
        @thread = nil
      end

      def restore_background
        @thread = Thread.new do
          restore
        end
      end

      def restore
        cleanup if self.class.restore_steps_path.exist?

        self.class.steps.each do |component|
          set_step(component)
          send(component)
          if any_errors?
            cleanup
            @backup.errors.add(:restore, error_messages.join(" - "))
            Thread.exit if @thread
            return false
          end
          # set_failed is called directly after the fail
          if component == :restore_database && !self.class.failed_path.exist?
            set_success
          end
        end

        cleanup
        true
      end

      class << self
        def status
          {
            steps: steps_done,
            success: success?,
            failed: failed?,
            restoring: restoring?
          }
        end

        def steps
          [
            :restore_crowbar,
            :run_installer,
            :restore_chef_keys,
            :restore_chef,
            :restore_database
          ]
        end

        def restore_steps_path
          install_dir_path.join("restore_steps")
        end

        def install_dir_path
          Pathname.new("/var/lib/crowbar/install")
        end

        def failed_path
          install_dir_path.join("crowbar-restore-failed")
        end

        def success_path
          install_dir_path.join("crowbar-restore-ok")
        end

        def purge
          [:restore_steps, :failed, :success].each do |p|
            send("#{p}_path").delete if send("#{p}_path").exist?
          end
          Crowbar::Installer.failed_path.delete if Crowbar::Installer.failed_path.exist?
        end

        protected

        def steps_done
          steps = []
          return nil unless restore_steps_path.exist?
          restore_steps_path.readlines.map(&:chomp).each do |step|
            steps.push step.split.last
          end
          steps
        end

        def failed?
          failed_path.exist?
        end

        def success?
          success_path.exist?
        end

        def restoring?
          restore_steps_path.exist?
        end
      end

      protected

      def cleanup
        self.class.restore_steps_path.delete
      end

      def any_errors?
        !errors.empty?
      end

      def errors
        @status.select { |k, v| v[:status] != :ok }
      end

      def error_messages
        errors.values.map { |e| e[:msg] }
      end

      def set_step(step)
        self.class.restore_steps_path.open("a") do |f|
          f.write "#{Time.zone.now.iso8601} #{step}\n"
        end
      end

      def set_failed
        ::FileUtils.touch(
          self.class.failed_path.to_s
        )
      end

      def set_success
        ::FileUtils.touch(
          self.class.success_path.to_s
        )
      end

      def restore_chef
        Rails.logger.debug "Restoring chef backup files"
        begin
          [:nodes, :roles, :clients, :databags].each do |type|
            Dir.glob(@data.join("knife", type.to_s, "**", "*")).each do |file|
              file = Pathname.new(file)
              # skip client "crowbar"
              next if type == :clients && file.basename.to_s =~ /^crowbar.json$/
              next unless file.extname == ".json"

              record = JSON.load(file.read)
              filename = file.basename.to_s
              if proposal?(file) && type == :databags
                Rails.logger.debug "Restoring proposal #{filename}"
                bc_name, prop = filename.split("-")
                prop.gsub!(/.json$/, "")
                proposal = Proposal.where(
                  barclamp: bc_name,
                  name: prop
                ).first_or_initialize(
                  barclamp: bc_name,
                  name: prop
                )
                proposal.properties = record.raw_data
                proposal.save
                begin
                  Rails.logger.debug "Migrating #{bc_name} schema"
                  SchemaMigration.run_for_bc(bc_name)
                rescue StandardError => e
                  set_failed
                  msg = I18n.t(
                    ".installer.upgrades.restore.schema_migration_failed",
                    bc_name: bc_name
                  )
                  Rails.logger.error("#{msg} -- #{e.message}")
                  @status[:restore_chef] = {
                    status: :conflict,
                    msg: msg
                  }
                end
              else
                record.save
              end
            end
          end

          @status[:restore_chef] ||= { status: :ok, msg: "" }
        rescue Errno::ECONNREFUSED
          raise Crowbar::Error::ChefOffline.new
        rescue Net::HTTPServerException
          raise "Restore failed"
        end

        Rails.logger.info("Re-running chef-client locally to apply changes from imported proposals")
        system(
          "sudo",
          "-i",
          "/usr/bin/chef-client",
          "-L",
          "#{ENV["CROWBAR_LOG_DIR"]}/chef-client/#{NodeObject.admin_node.name}.log"
        )
      end

      def restore_files(source, destination)
        # keep the permissions of the files that are already in place
        src_path = @data.join("crowbar", source)
        dest_is_dir = system("sudo", "test", "-d", destination)

        # If source and destination are both directories we just need to
        # copy the contents of source, not the directory itself.
        src_string = if dest_is_dir && src_path.directory?
          "#{src_path}/."
        else
          src_path.to_s
        end

        Rails.logger.debug "Copying #{src_string} to #{destination}"
        system(
          "sudo",
          "cp", "-a",
          src_string,
          destination
        )
      end

      def restore_crowbar
        Rails.logger.debug "Restoring crowbar backup files"
        Crowbar::Backup::Base.restore_files.each do |source, destination|
          restore_files(source, destination)
        end

        @status[:restore_crowbar] ||= { status: :ok, msg: "" }
      end

      def restore_chef_keys
        Rails.logger.debug "Restoring chef keys"
        Crowbar::Backup::Base.restore_files_after_install.each do |source, destination|
          restore_files(source, destination)
        end

        @status[:restore_chef_keys] ||= { status: :ok, msg: "" }
      end

      def run_installer
        Rails.logger.debug "Starting Crowbar installation"
        Crowbar::Installer.install!
        Rails.logger.debug "Waiting for installation to be successful"
        sleep(1) until Crowbar::Installer.successful? || Crowbar::Installer.failed?

        if Crowbar::Installer.failed?
          Rails.logger.debug "Crowbar Installation Failed"
          set_failed
          @status[:run_installer] = {
            status: :not_acceptable,
            msg: I18n.t("installer.installers.status.installation_failed")
          }
        end

        @status[:run_installer] ||= { status: :ok, msg: "" }
      end

      def restore_database
        Rails.logger.debug "Restoring Crowbar database"
        migrate_database(:before)

        begin
          SerializationHelper::Base.new(YamlDb::Helper).load(
            @data.join("crowbar", "database.yml")
          )
        rescue StandardError => e
          Rails.logger.debug "Failed to load database.yml: #{e}"
          set_failed
          @status[:restore_database] = {
            status: :not_acceptable,
            msg: I18n.t("backups.index.restore_database_failed")
          }
        end

        migrate_database(:after)

        @status[:restore_database] ||= { status: :ok, msg: "" }
      end

      def proposal?(file)
        return false if file.basename.to_s =~ /^template-(.*).json$/ || \
            !file.to_s =~ /knife\/databags\/crowbar/
        raw_data = JSON.parse(file.read)["raw_data"]
        return false if raw_data.nil?
        raw_data.key?("attributes") && raw_data.key?("deployment")
      end

      def migrate_database(time)
        Crowbar::Migrate.migrate!
      rescue SQLite3::SQLException => e
        Rails.logger.debug "Failed to migrate database #{time} loading: #{e}"
        set_failed
        @status[:restore_database] = {
          status: :not_acceptable,
          msg: I18n.t("backups.index.migrate_database_failed")
        }
      end
    end
  end
end
