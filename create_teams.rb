require "debug"
require "yaml"
require "octokit"
require "dotenv/load"

class TeamStructure

    def initialize
        @client = Octokit::Client.new(:access_token => ENV["GH_TOKEN"])
        @client.auto_paginate = true
        @failed_team_creation = {}
        @created_teams = []
        @hierarchy = YAML.load_file("teams.yml")
    end

    def build_team_hierarchy(lineage = @hierarchy, parent_id = nil)
        lineage.each do |team|
            if parent_id.nil?
                # If there's no parent, then create the team without an ID
                team_data = {:name => team[:team_name], :privacy => "closed"}
            else 
                team_data = {:name => team[:team_name], :parent_team_id => parent_id, :privacy => "closed"}
            end
          
            begin
                # Create the team
                created_team = @client.create_team(ENV["GH_TARGET_ORG"], team_data)
                @created_teams << created_team[:name]
                team[:team_id] = created_team[:id]
      
                # Recursively create child teams
                build_team_hierarchy(team[:children], created_team[:id]) unless team[:children].empty?
            rescue Octokit::Error => e
                @failed_team_creation[team[:team_name]] = e.message
            end
        end
    end
      
    def write_logs
        timestamp = Time.now.strftime("%Y-%m-%d-%H-%M-%S")
        file_name = "logs/create_teams_log_#{timestamp}.txt"
        File.open("#{file_name}", "w") do |file|
            puts "Writing logs to logs/get_teams_log_#{timestamp}.txt... 📝"
            file.puts "- Created #{@created_teams.length} teams in #{ENV["GH_TARGET_ORG"]}"
            file.puts " "
            # If we had some failed team creations, write a log of those
            if !@failed_team_creation.empty?
                @failed_team_creation.each do |key, value|
                    file.puts "-----------------"
                    file.puts "Couldn't create #{key}. Reason: #{value}"
                end
            end
        end
    end

    def run_script
        puts "Creating teams in #{ENV["GH_TARGET_ORG"]}... 🏗"
        build_team_hierarchy
        write_logs
    end
end

team_structure = TeamStructure.new
team_structure.run_script

