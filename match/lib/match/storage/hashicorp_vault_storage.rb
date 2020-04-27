require 'fastlane_core/command_executor'
require 'fastlane_core/configuration/configuration'
require 'vault'
require 'base64'
require 'fileutils'

require_relative '../options'
require_relative '../module'
require_relative '../spaceship_ensure'
require_relative './interface'

module Match
  module Storage
    # Store the code signing identities in HashiCorp Vault Storage
    class HashiCorpVaultStorage < Interface
      VAULT_TOKEN_FILE_NAME = ".vault-token"

      # User provided values
      attr_reader :type
      attr_reader :platform
      attr_reader :readonly
      attr_reader :username
      attr_reader :team_id
      attr_reader :team_name
      attr_reader :vault_addr

      # Managed values
      attr_accessor :vault_client

      def self.configure(params)
        if params[:git_url].to_s.length > 0
          UI.important("Looks like you still define a `git_url` somewhere, even though")
          UI.important("you use HashiCorp Vault Storage. You can remove the `git_url`")
          UI.important("from your Matchfile and Fastfile")
          UI.message("The above is just a warning, fastlane will continue as usual now...")
        end

        return self.new(
          type: params[:type].to_s,
          platform: params[:platform].to_s,
          readonly: params[:readonly],
          username: params[:username],
          team_id: params[:team_id],
          team_name: params[:team_name],
          vault_addr: params[:vault_addr]
        )
      end

      def initialize(type: nil,
                     platform: nil,
                     readonly: nil,
                     username: nil,
                     team_id: nil,
                     team_name: nil,
                     vault_addr: nil)
        @type = type if type
        @platform = platform if platform

        @readonly = readonly
        @username = username
        @team_id = team_id
        @team_name = team_name

        @vault_addr = vault_addr if vault_addr

        unless vault_addr
          @vault_addr = UI.input("URL of the HashiCorp Vault Server: ")
        end

        vault_token_file = File.join(ENV['HOME'], VAULT_TOKEN_FILE_NAME)
        unless File.exist?(vault_token_file)
          UI.user_error!("No vault session found. Please perform a `vault login` and re-run this command")
        end

        begin
          # Extract the token from the file
          token_file_contents = File.read(vault_token_file)

          # Create the HashiCorp Vault client
          self.vault_client = Vault::Client.new(address: self.vault_addr)
          self.vault_client.auth.token(token_file_contents)
        rescue => ex
          UI.error(ex)
          UI.verbose(ex.backtrace.join("\n"))
          UI.user_error!("Invalid vault session found. Please perform a `vault login` and re-run this command")
        end
      end

      def currently_used_team_id
        if self.readonly
          # In readonly mode, we still want to see if the user provided a team_id
          # see `prefixed_working_directory` comments for more details
          return self.team_id
        else
          spaceship = SpaceshipEnsure.new(self.username, self.team_id, self.team_name)
          return spaceship.team_id
        end
      end

      def prefixed_working_directory
        # We fall back to "*", which means certificates and profiles
        # from all teams that use this bucket would be installed. This is not ideal, but
        # unless the user provides a `team_id`, we can't know which one to use
        # This only happens if `readonly` is activated, and no `team_id` was provided
        @_folder_prefix ||= currently_used_team_id
        if @_folder_prefix.nil?
          # We use a `@_folder_prefix` variable, to keep state between multiple calls of this
          # method, as the value won't change. This way the warning is only printed once
          UI.important("Looks like you run `match` in `readonly` mode, and didn't provide a `team_id`. This will still work, however it is recommended to provide a `team_id` in your Appfile or Matchfile")
          @_folder_prefix = "*"
        end
        return File.join(working_directory, @_folder_prefix)
      end

      def download
        # Check if we already have a functional working_directory
        return if @working_directory

        # No existing working directory, creating a new one now
        self.working_directory = Dir.mktmpdir

        unless self.team_id || self.type
          begin
            # List the secrets using the HashiCorp Vault client
            secrets = []

            ['certs', 'profiles'].each do |t|
              path = 'match/' + self.team_id + '/' + t + '/' + self.type
              result = self.vault_client.logical.list(path)
              result.each { |r| secrets.push(path + '/' + r) }
            end

            # Get the secrets and write them out
            secrets.each do |secret|
              UI.verbose("Downloading secret from HashiCorp Vault '#{secret}'")
              result = self.vault_client.logical.read(secret)
              split = secret.split('/')
              filename = split[split.length - 1]
              path = self.working_directory + '/' + secret.gsub('/' + filename, '').gsub('match/', '')
              dirname = File.dirname(path)
              unless File.directory?(dirname)
                FileUtils.mkdir_p(dirname)
              end
              File.write(dirname + '/' + filename, Base64.decode64(result.data[:data][:contents]))
            end
          rescue => ex
            UI.error(ex)
            UI.user_error!("Unable to get secrets from vault and write to file.")
          end
          UI.verbose("Successfully downloaded secrets from Vault to #{self.working_directory}")
        end
      end

      def delete_files(files_to_delete: [], custom_message: nil)
        puts("delete_files")
        puts(caller)
        # files_to_delete.each do |current_file|
        #  target_path = current_file.gsub(self.working_directory + "/", "")
        #  file = bucket.file(target_path)
        #  UI.message("Deleting '#{target_path}' from Google Cloud Storage bucket '#{self.bucket_name}'...")
        #  file.delete
        # end
      end

      def human_readable_description
        "HashiCorp Vault [#{self.vault_addr}]"
      end

      def upload_files(files_to_upload: [], custom_message: nil)
        # `files_to_upload` is an array of files that need to be uploaded to HashiCorp Vault
        # Those doesn't mean they're new, it might just be they're changed
        # Either way, we'll upload them using the same technique
        files_to_upload.each do |current_file|
          target_path = current_file.gsub(self.working_directory, "")

          next unless target_path.start_with?('/')
          begin
            # Extract the contents from the file and base64 encode
            file_contents = Base64.encode64(File.read(current_file))
            # Create the secret using the HashiCorp Vault client
            self.vault_client.logical.write('match' + target_path, data: { contents: file_contents })
          rescue => ex
            UI.error(ex)
            UI.user_error!("Unable to write file to vault.")
          end
        end
      end

      def skip_docs
        false
      end

      def generate_matchfile_content
        return "vault_addr(\"#{self.vault_addr}\")"
      end
    end
  end
end
