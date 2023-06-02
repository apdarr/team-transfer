# Scripts for migrating teams and repos to a new GitHub organization 

This directory contains three scripts for to help migrate teams and repositories to a new GitHub organization. Note that the purpose of this utility is to transfer teams' repos _between orgs within the same GitHub enterprise account_. This utility covers: three main areas: 

- [Creating a list of current teams](#migrating-teams): `get-teams.rb`
- [Migrating teams](#migrating-teams): `create_teams.rb`
- [Migrating repositories](#migrating-repositories): `transfer_repos.rb`
- [Inviting members](#inviting-members): `invite_members.rb`

# Setting up your environment
The scripts require a few dependencies, most notably [Octokit](https://github.com/octokit/octokit.rb). In order to start using these scripts, we first have to ensure Ruby is installed on your machine. You can confirm this by running `ruby -v` in your terminal. If you don't have Ruby installed, you can download it [here](https://www.ruby-lang.org/en/downloads/) for your particular OS. If running on macOS, your machine should already have Ruby installed.

The scripts also require a few [Ruby gems](https://guides.rubygems.org/what-is-a-gem/) to be installed. You can install these by running `bundle install` in the working directory:

1. Once you've installed Ruby, navigate to the working directory in your terminal.
2. Install bundler with `gem install bundler` (if running on macOS, your machine should already have Ruby installed).
3. In your terminal, run `bundle install` to install the dependencies.
4. This will generate a new file, Gemfile.lock, which contains the specific versions of the gems that were installed. If you're coming from the Node.js world, this Gemfile.lock file is similar [to `the package-lock.json` file](https://docs.npmjs.com/cli/v9/configuring-npm/package-lock-json). 

## Create your .env file 
THis script requires a few environment variables to be set. You can do this by creating a `.env` file in the working directory. I've created a `.env.sample` file to get started. Rename this file to be `.env` file, which should contain the following variables:
- `GH_ORG=` the name of the source organization, i.e. the organization _from_ which you're transferring teams and repos 
- `GH_TARGET_ORG=` the name of the destination organization, i.e. the organization _to_ which you're transferring teams and repos
- `GH_TOKEN=` your personal access token. This should have the `admin:org` scope, and the user must be an org owner of both source and target orgs

Once you've finished editing these values, you should have a .env file in the working directory that looks like this: 

```
GH_ORG=my-source-org
GH_TARGET_ORG=my-target-org
GH_TOKEN=ghp_1234abcd
```

# Migrating teams

For creating teams in the new, target organization, we'll need to create a list of the current teams in the source organization. This will be used to create the teams in the target organization, and to transfer the repositories owned by those source teams.

To start, run `ruby get_teams.rb` in your terminal from the working directory. This will generate a new file, `teams.yml`, which contains the team names and their corresponding members.

:point_right: **Using this .yml file** delete any top-level teams (and their child descendants) that you _don't_ want to migrate. 

Next, the `create_teams.rb` script will create new teams in the destination organization. A seperate script (see: [Inviting members](#inviting-members)) will later be used to invite users to the organization and their respective team(s).

Once you've edited the `teams.yml` file, you can run `ruby create_teams.rb` again to create the teams in the destination organization.

:point_right: After you've successfully created teams in the target org, don't delete any teams in the _source_ org until you're satisified and fully finished with team transfer exercise. There may be a case where we need to re-run scripts, which would depend on having an accurate source org.

# Inviting members

The `invite_members.rb` script will invite all members of the source organization to the destination organization.

**Note** This script depends on the generated, and edited `teams.yml` file generated above. 

Once you've migrated you've transferred your repos successfully, run `ruby invite_members.rb` in your terminal from the working directory. This will invite all members of the source organization to the destination organization.

# Migrating repositories

The `transfer_repos.rb` script will transfer team-owned repositories from the source organization to the destination organization. 

**Two points to note** 

The `transfer_repos.rb` script will only transfer repositories that are owned by teams. If you want to transfer repositories that are owned by individuals, you'll have to do this manually, or we can devise a workaround for this - just let @apdarr know!
 
Once ready, run `ruby transfer_repos.rb` in your terminal from the working directory. This will start the transfer process for moving repos from source to target org. Any repos that can't be migrated due to exceptions [listed here](https://docs.github.com/en/enterprise-cloud@latest/repositories/creating-and-managing-repositories/transferring-a-repository#about-repository-transfers) will be listed in the `failed_repos.txt` log file.

Additionally, the `transfer_repos.rb` script captures the team and user permissions on each repo in the source org. Based on the repos that have been transferred, the script then applies team and user access permissions to those repos. **Note**: this process will create a file called `teams_access_by_repo.yaml`, which is imply used by subsequent processing in the script. 