require "dotenv/load"
require "debug"
require "yaml"
require "optparse"

options = { :env_file => ".env" }

OptionParser.new do |opts|
    opts.banner = "Usage: invite_members.rb [options]"

    opts.on("-eENV_FILE", "--env=ENV_FILE", "Path to .env file") do |env_file|
        options[:env_file] = env_file
    end
end.parse!

Dotenv.load(options[:env_file])


class InviteMembers

    def initialize
        @client = Octokit::Client.new(:access_token => ENV["GH_TOKEN"], :api_endpoint => ENV.fetch('GH_REST_API', 'https://api.github.com'))
        @client.auto_paginate = true
        @hierarchy = YAML.load_file("teams.yml")
        @initial_org_members_count = @client.org_members(ENV["GH_ORG"]).count
        @existing_target_org_members = @client.org_members(ENV["GH_TARGET_ORG"]).map { |m| m[:login] }
        @failed_invites = {}
        @invited_members = []
    end

     # We need the team id in the target org in order to correctly invite users to the matching org team
     def target_team_id(team_name)
        all_teams = @client.org_teams(ENV["GH_TARGET_ORG"])
        team = all_teams.find { |team| team[:name] == team_name }
        team_id = team[:id]
        # Method returns the team id
        return team_id
    end

    def invite_member(member, team)
        target_team_id_value = target_team_id(team[:team_name])
        
        begin
            # Leaving this API uncommented for now, in case we want to return to using an API method for checking existing invites
            # If the user has not already been invited and is not already a member of the target org, invite them
            if !@invited_members.include?(member) && !@existing_target_org_members.include?(member)
                @client.update_organization_membership(ENV["GH_TARGET_ORG"], user: member, role: "member")
                last_response = @client.last_response
                    if last_response.status == 200
                        @invited_members << member 
                        puts "📨 Invited #{member} to org #{ENV["GH_TARGET_ORG"]}, to team #{team[:team_name]}"  
                    end
            elsif @existing_target_org_members.include?(member)
                puts "#{member} is already a member of #{ENV["GH_TARGET_ORG"]}, adding to team #{team[:team_name]}"
                if team[:maintainers].include?(member)
                    # Add user as a maintainer to the the team if they're defined as a maintainer in the YAML file
                    @client.add_team_membership(target_team_id_value, member, role: "maintainer")
                else
                    @client.add_team_membership(target_team_id_value, member)
                end

            end
        rescue Octokit::Error => e
          error_message = "Failed to invite #{member} to org #{ENV["GH_TARGET_ORG"]}: #{e.message}"
          error_message = "Failed to add #{member} to org #{ENV["GH_TARGET_ORG"]}: #{e.message}" if @existing_target_org_members.include?(member)
          @failed_invites[member] = e.message
        end
    end
      
    def parse_teams(hierarchy = @hierarchy)
        hierarchy.each do |team|
            # We want to iterate through all members: maintainers and team members
            all_members = team[:members] + team[:maintainers]
            if !team[:children].nil?
                all_members.each do |member|
                    invite_member(member, team)
                end
                parse_teams(team[:children])
            else 
                all_members.each do |member|
                    invite_member(member, team)
                end
            end
            
            if !ENV["ADMIN_TO_DELETE"].nil?
                 puts "Deleting specified admin #{ENV["ADMIN_TO_DELETE"]} from #{team[:team_name]}"
                 target_team_id_value = target_team_id(team[:team_name])
                 @client.remove_team_membership(target_team_id_value, ENV["ADMIN_TO_DELETE"])
            end
        end
    end

    def write_logs
        timestamp = Time.now.strftime("%Y-%m-%d-%H-%M-%S")
        file_name = "logs/invite_members_log_#{timestamp}.txt"
        File.open("#{file_name}", "w") do |file|
            puts "📝 Writing logs to #{file_name}"
            file.puts "- Current org members count in #{ENV["GH_ORG"]}: #{@initial_org_members_count}"
            file.puts "- Invited #{@invited_members.count} members to #{ENV["GH_TARGET_ORG"]}:"
            @invited_members.each do |member|
                file.puts "-- #{member}"
            end
            if @failed_invites.count > 0
                file.puts " "
                file.puts "- Failed to invite some members:"
                @failed_invites.each do |key, value|
                    file.puts "Couldn't invite #{key}. Reason: #{value}"
                    file.puts "-----------------"
                end
            end
        end
    end

    def run_script
        puts "Inviting members to new org... 📨"
        parse_teams
        write_logs
    end
end

invite = InviteMembers.new
invite.run_script
