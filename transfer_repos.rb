require "octokit"
require "debug"
require "yaml"
require "pp"
require "hashie"
require "optparse"

options = { :env_file => ".env" }

OptionParser.new do |opts|
    opts.banner = "Usage: transfer_repos.rb [options]"

    opts.on("-eENV_FILE", "--env=ENV_FILE", "Path to .env file") do |env_file|
        options[:env_file] = env_file
    end
end.parse!

Dotenv.load(options[:env_file])

class TransferRepos

    # Initiatlize with Octokit and the teams.yml file generate from create_teams.rb
    def initialize
        @client = Octokit::Client.new(:access_token => ENV["GH_TOKEN"], :api_endpoint => ENV.fetch('GH_REST_API', 'https://api.github.com'))
        @client.auto_paginate = true
        @hierarchy = YAML.load_file("teams.yml")
        @hierarchy.extend Hashie::Extensions::DeepFind
        @transferred_repos = []
        @untransferred_repos = {}
        @untransferred_access = {}
        @permission_hash = {}
        @permission_hash.extend Hashie::Extensions::DeepFind
        @source_org_users = []
        @target_org_members = @client.org_members(ENV["GH_TARGET_ORG"]).map { |member| member.login }
    end

    # We need the team id in the target org in order to correctly set their permissions on any given repo
    def target_team_id(team_name)
        all_teams = @client.org_teams(ENV["GH_TARGET_ORG"])
        team = all_teams.find { |team| team[:name] == team_name }
        team_id = team[:id]
        # Method returns the team id
        return team_id
    end

    def transfer_team_repos(team_id, team_name)
        repos = @client.team_repos(team_id)
        repos.each do |repo|
            begin 
                if !@transferred_repos.include?(repo.name) && !@untransferred_repos.include?(repo.name)
                    @client.transfer_repo(repo.id, ENV["GH_TARGET_ORG"])
                    sleep 1
                    response = @client.last_response
                    if response.status == 202 
                        puts "Successfully transferred #{repo.name} to #{ENV["GH_TARGET_ORG"]} ✅"
                        sleep 1
                        @transferred_repos << repo.name
                    end
                end
            rescue Octokit::Error => e
                puts "Error transferring repo #{repo.name}: #{e.message}. Skipping. ❌"
                @untransferred_repos[repo.name] = e.message
            end
        end
    end

    def transfer_access_permissions 
        file = YAML.load_file("teams_access_by_repo.yaml")
     
        # Parse each file and create the teams in the new org
        file.each do |repo, access_group|
            # For each repo, iterate through the access group, i.e. the mix of teams and users that have access to the repo
            # The permission_hash doesn't differentiate whether access is granted to a user or a team. In other words, "entity" can be either a user or a team
            access_group.each do |entity, permission|
                if @transferred_repos.include?(repo) && !@untransferred_repos.include?(repo)
                    # Check if we're dealing with a user or a team for the entity
                    # Here, we checking whether the entity is an org member, i.e. a user
                    if @target_org_members.include?(entity)
                        repo_full_name = ENV["GH_TARGET_ORG"] + "/" + repo
                        puts "Adding #{entity} to #{repo} with #{permission} permissions"

                        # The add_collaborator method will add an org member to a repo with the specified permissions. 
                        @client.add_collaborator(repo_full_name, entity, permission: permission)
                    # If the entity on the original org is not a member of the target org, add them as an outside collab. 
                    elsif @source_org_users.include?(entity)
                        repo_full_name = ENV["GH_TARGET_ORG"] + "/" + repo
                        puts "Adding #{entity} to #{repo} with #{permission} permissions"

                        # The add_collaborator method will add an org member to a repo with the specified permissions. 
                        # While the method call is the same as the above `if` statement, the checks are different for clarity purposes.
                        @client.add_collaborator(repo_full_name, entity, permission: permission)
                    else
                        puts "Adding #{entity} to #{repo} with #{permission} permissions"
                
                        # If the entity is a team, we need to get the team id from its name
                        # Get the team ID from its name
                        team_id_value = target_team_id(entity)
                        repo_full_name = ENV["GH_TARGET_ORG"] + "/" + repo
                        # Update the repository permissions for the team
                        @client.add_team_repository(team_id_value, repo_full_name, permission: permission)
                    end 
                end
                last_response = @client.last_response
                # If the last response is in the 200 range, the operation was successful
                if last_response.status == (200..299)
                    puts "Successfully added #{entity} to #{repo} with #{permission} permissions ✅"
                end
            rescue Octokit::Error => e
                puts e.message
                @untransferred_access[repo] = e.message
            end
        end
    end

    def write_failed_repos
        timestamp = Time.now.strftime("%Y-%m-%d-%H-%M-%S")
        file_name = "logs/transfer_repos_log_#{timestamp}.txt"

        puts "Writing transfer_repos output to file... 📝"
        puts "Writing logs to logs#{file_name}... 📝"
        
        File.open("#{file_name}", "w") do |f|
            f.puts "Results of transfer operation:"
            f.puts "Successfully transferred #{@transferred_repos.count} repos: #{@transferred_repos}"
            if @untransferred_repos.count > 0
                puts " "
                puts "Failed to transfer some repos. See #{file_name} for more details."
                @untransferred_repos.each do |key, value|
                    f.puts " "
                    f.puts "-----------------"
                    f.puts "Couldn't transfer #{key}. Reason: #{value}"
                end
            end

            if @untransferred_access.count > 0
                puts " "
                puts "Failed to transfer some user or team access to repos. See #{file_name} for more details."
                @untransferred_access.each do |key, value|
                    f.puts " "
                    f.puts "-----------------"
                    f.puts "Couldn't transfer some access to repo #{key}. Reason: #{value}"
                end
            end
        end
    end
    
    def team_permissions_per_repo
        @client.org_repos(ENV["GH_ORG"]).each do |repo|
            source_repo = ENV["GH_ORG"] + "/" + repo.name
            # Get the users added to the repo: both outside collabs and users with direct access
            users = @client.collaborators(source_repo, affiliation: "direct")
            # Assuming we have users in our array, we can iterate through them and add them to our permissions hash
            if !users.empty?
                users.each do |user| 
                    user_permission = { user.login => user.permissions.to_h.find { |key, value| value == true }.first.to_s }
                    @permission_hash[repo.name] ||= {}
                    @permission_hash[repo.name].merge!(user_permission)
                    # When capturing the users, we want to add them to a separate array so we can check if they're source org members in transfer_access_permissions, thereby indicating they should outside collabs
                    @source_org_users << user.login
                end
            end
            # Next, add the teams to their repositories
            repo_teams = @client.repo_teams(source_repo)
            
            # If the repo has teams, add them to the permissions hash
            if !repo_teams.empty?
                repo_teams.each do |t|
                    team_name = t[:name]
                    permission = t[:permissions].to_h.find { |key, value| value == true }.first.to_s
                    team_permission = { team_name => permission }
                    @permission_hash[repo.name] ||= {}
                    @permission_hash[repo.name].merge!(team_permission)
                end
            end
        end

        File.open("teams_access_by_repo.yaml", "w") do |file|
            file.write @permission_hash.to_yaml
        end
    end
    
    def parse_hierarchy(hierarchy = @hierarchy)
        hierarchy.each do |team|
            transfer_team_repos(team[:team_id], team[:team_name])
            if !team[:children].nil?
                parse_hierarchy(team[:children])
            end
        end
    end

    def process_repos
        puts "Starting transfer operation... 🚛"
        team_permissions_per_repo
        parse_hierarchy
        transfer_access_permissions
        write_failed_repos
    end
end

repos = TransferRepos.new
repos.process_repos
