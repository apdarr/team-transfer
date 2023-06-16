require "hashie"
require "debug"
require "yaml"
require "octokit"
require "graphql/client"
require "graphql/client/http"
require "dotenv"
require "optparse"

options = { :env_file => ".env" }

OptionParser.new do |opts|
    opts.banner = "Usage: get_teams.rb [options]"

    opts.on("-eENV_FILE", "--env=ENV_FILE", "Path to .env file") do |env_file|
        options[:env_file] = env_file
    end
end.parse!

Dotenv.load(options[:env_file])

module GitHub
    HTTP = GraphQL::Client::HTTP.new(ENV.fetch('GH_GRAPHQL_API', 'https://api.github.com/graphql')) do
        def headers(context)
            {
                "Authorization" => "Bearer #{ENV["GH_TOKEN"]}",
                "User-Agent" => 'Ruby'
            }
        end
    end  
  
    # Fetch latest schema on init, this will make a network request
    Schema = GraphQL::Client.load_schema(HTTP)
  
    Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
  
    class Team
        DirectMembership = GitHub::Client.parse <<-'GRAPHQL'
            query($teamSlug: String!, $org: String!, $after: String) {
                organization(login: $org) {
                    team(slug: $teamSlug) {
                    name
                    members(membership: IMMEDIATE, first: 100, after: $after) {
                        totalCount
                        pageInfo {
                        endCursor
                        hasNextPage
                        }
                        nodes {
                        login
                        }
                    }
                    }
                }
                }
            GRAPHQL
  
        def self.direct_membership(team_name)
            # Initialize the list of login names and the `after` cursor
            login_names = []
            after_cursor = nil

            loop do
            # Query for the next page of members using the `after` cursor
                response = Client.query(DirectMembership, variables: { org: ENV["GH_ORG"], teamSlug: team_name, after: after_cursor })
                if response.errors.any?
                    raise QueryExecutionError.new(response.errors[:data].join(", "))
                end

                # Extract the login names from the current page of members
                nodes = response.to_h.dig("data", "organization", "team", "members", "nodes")
                login_names = []

                if nodes && !nodes.empty?
                    login_names += nodes.map { |node| node["login"] }
                end
            
                # Check if there are more pages of members to fetch
                page_info = response.to_h.dig("data", "organization", "team", "members", "pageInfo")
                break unless page_info && page_info["hasNextPage"]

                # Update the `after` cursor to the end of the current page
                after_cursor = page_info["endCursor"]
            end
        login_names
        end
    end
end
  

class TeamStructure 
    
    def initialize 
        @client = Octokit::Client.new(:access_token => ENV["GH_TOKEN"], :api_endpoint => ENV.fetch('GH_REST_API', 'https://api.github.com'))
        @client.auto_paginate = true
        @teams = @client.org_teams(ENV["GH_ORG"])
        @hierarchy = []
        @team_count = @client.org_teams(ENV["GH_ORG"]).count
    end
   
    def build_hierarchy
        # Create a hash to hold all teams by team_name
        team_hash = {}
        @hierarchy.each do |team|
            team_hash[team[:team_name]] = team
            team[:children] = []
        end
        
        # Traverse the teams and add them to their parent's children array
        @hierarchy.each do |team|
            parent = team[:parent]
            if parent.nil?
                next
            end
            parent_team = team_hash[parent]
            parent_team[:children] << team
        end
        # Filter out all teams that have a parent (we only want the top-level teams)
        @hierarchy = @hierarchy.select { |team| team[:parent].nil? }
    end
      
    
    def get_team_hierarchy
        puts "Fetching team hierarchy... ⚽️"

        @teams.each do |api_team|
            # Capture orphaned teams
            if api_team.parent.nil?
                team_hash = {team_name: api_team.name, team_id: api_team.id, parent: nil, children: nil}
                @hierarchy << team_hash
            else 
                # If the team has a parent, which has a parent, create a recursive call to find the parent's parent
                team_hash = {team_name: api_team.name, team_id: api_team.id, parent: api_team.parent.name, children: nil}
                @hierarchy << team_hash
            end
        end
    end

    def fetch_team_membership(hierarchy)
        hierarchy.each do |team|
            team_members = GitHub::Team.direct_membership(team[:team_name].downcase.gsub(/\s+/, '-'))
            team_maintainers = []

            # If the team has users, grab their maintainers
            if !team_members.empty?
                team_maintainers = team_members.select { |member| @client.team_membership(team[:team_id], member).role == "maintainer" }
            end

            # Filter out the maintainers from the members array
            team[:members] = team_members - team_maintainers
            team[:maintainers] = team_maintainers

            new_key_order = [:team_name, :team_id, :parent, :members, :maintainers, :children]
            # Reorder the key-value pairs based on the new array
            team.replace(team.slice(*new_key_order).merge(team.except(*new_key_order)))
            if !team[:children].nil?
                fetch_team_membership(team[:children])
            end
        end
    end

    def write_teams_file
        fetch_team_membership(@hierarchy)

        puts "Writing team hierarchy to file... 📝"

        File.open("teams.yml", "w") do |file|
            file.write @hierarchy.to_yaml
        end
    end

    def count_teams(teams)
        count = teams.size
        teams.each do |team|
            count += count_teams(team[:children]) if team[:children]
        end
        count
    end

    def write_logs
        teams_file = YAML.load_file("teams.yml")
        parsed_team_count = count_teams(teams_file)
        timestamp = Time.now.strftime("%Y-%m-%d-%H-%M-%S")
        file_name = "logs/get_teams_log_#{timestamp}.txt"
        File.open("#{file_name}", "w") do |file|
            puts "Writing logs to #{file_name}... 📝"
            file.puts "- Initial team members count in #{ENV["GH_ORG"]}: #{@team_count}"
            file.puts "- Successfully parsed #{parsed_team_count} teams within #{ENV["GH_ORG"]}"
            file.puts "------"
        end
    end

    def run_script
        get_team_hierarchy
        build_hierarchy
        write_teams_file 
        write_logs
    end
end

team_structure = TeamStructure.new
team_structure.run_script
