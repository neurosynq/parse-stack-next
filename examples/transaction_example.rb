#!/usr/bin/env ruby
# Transaction Example for Parse-Stack
#
# This example demonstrates how to use transactions to ensure atomic operations
# across multiple Parse objects.

require 'parse/stack'

# Configure your Parse application
Parse.setup(
  app_id: ENV['PARSE_APP_ID'] || 'your-app-id',
  api_key: ENV['PARSE_API_KEY'] || 'your-api-key',
  server_url: ENV['PARSE_SERVER_URL'] || 'http://localhost:1337/parse'
)

# Define example models
class Team < Parse::Object
  property :name
  property :owner, :pointer, class_name: 'User'
  property :member_count, :integer, default: 0
end

class Membership < Parse::Object
  property :user, :pointer, class_name: 'User'
  property :team, :pointer, class_name: 'Team'
  property :access_level, :string
  property :grant, :string
end

class Project < Parse::Object
  property :name
  property :team, :pointer, class_name: 'Team'
  property :owner, :pointer, class_name: 'User'
end

# Example 1: Basic transaction with explicit batch operations
def transfer_project_ownership_basic(project, new_owner)
  Parse::Object.transaction do |batch|
    # Get old owner
    old_owner = project.owner
    
    # Find or create new owner membership
    new_owner_membership = Membership.first(
      project: project,
      user: new_owner
    )
    
    if new_owner_membership.nil?
      new_owner_membership = Membership.new(
        project: project,
        team: project.team,
        user: new_owner,
        grant: 'project',
        access_level: 'owner'
      )
      batch.add(new_owner_membership)
    else
      new_owner_membership.access_level = 'owner'
      batch.add(new_owner_membership)
    end
    
    # Demote old owner if they have a membership
    if old_owner.present?
      old_owner_membership = Membership.first(
        project: project,
        user: old_owner
      )
      
      if old_owner_membership.present?
        old_owner_membership.access_level = 'admin'
        batch.add(old_owner_membership)
      end
    end
    
    # Update project owner
    project.owner = new_owner
    batch.add(project)
  end
  
  puts "Successfully transferred ownership"
rescue Parse::Error => e
  puts "Transaction failed: #{e.message}"
  false
end

# Example 2: Transaction with automatic batching via return value
def transfer_project_ownership_auto(project, new_owner)
  results = Parse::Object.transaction do
    old_owner = project.owner
    objects_to_save = []
    
    # Find or create new owner membership
    new_owner_membership = Membership.first(
      project: project,
      user: new_owner
    ) || Membership.new(
      project: project,
      team: project.team,
      user: new_owner,
      grant: 'project'
    )
    
    new_owner_membership.access_level = 'owner'
    objects_to_save << new_owner_membership
    
    # Demote old owner
    if old_owner.present?
      old_owner_membership = Membership.first(
        project: project,
        user: old_owner
      )
      
      if old_owner_membership.present?
        old_owner_membership.access_level = 'admin'
        objects_to_save << old_owner_membership
      end
    end
    
    # Update project
    project.owner = new_owner
    objects_to_save << project
    
    # Return array of objects to be saved in transaction
    objects_to_save
  end
  
  puts "Transaction completed with #{results.count} operations"
  true
rescue Parse::Error => e
  puts "Transaction failed: #{e.message}"
  false
end

# Example 3: Complex transaction with validation
def complex_team_operation(team, new_members, new_owner)
  Parse::Object.transaction(retries: 3) do |batch|
    # Validate new owner is in new members list
    unless new_members.include?(new_owner)
      raise Parse::Error, "New owner must be in members list"
    end
    
    # Update team
    team.owner = new_owner
    team.member_count = new_members.count
    batch.add(team)
    
    # Create memberships for all new members
    new_members.each do |member|
      membership = Membership.new(
        team: team,
        user: member,
        grant: 'team',
        access_level: member == new_owner ? 'owner' : 'member'
      )
      batch.add(membership)
    end
    
    # Create a project for the team
    project = Project.new(
      name: "#{team.name} Project",
      team: team,
      owner: new_owner
    )
    batch.add(project)
  end
  
  puts "Complex operation completed successfully"
rescue Parse::Error => e
  puts "Complex operation failed: #{e.message}"
  raise # Re-raise to propagate error
end

# Example 4: Transaction with conflict retry
def increment_counters_with_retry(objects)
  Parse::Object.transaction(retries: 10) do
    objects.each do |obj|
      obj.increment(:counter)
    end
    objects # Return objects to be saved
  end
rescue Parse::Error => e
  if e.message.include?("251")
    puts "Transaction conflict after all retries"
  else
    puts "Transaction error: #{e.message}"
  end
  raise
end

# Main execution examples
if __FILE__ == $0
  puts "Parse Transaction Examples"
  puts "========================="
  
  begin
    # Example usage (requires actual Parse server and data)
    # project = Project.first
    # new_owner = Parse::User.first(username: "new_owner")
    # 
    # if project && new_owner
    #   transfer_project_ownership_basic(project, new_owner)
    # end
    
    puts "\nTransaction support has been added to parse-stack!"
    puts "\nKey features:"
    puts "1. Atomic operations - all succeed or all fail"
    puts "2. Automatic retry on transaction conflicts (error 251)"
    puts "3. Two styles: explicit batch.add() or return array"
    puts "4. Works with any Parse::Object subclass"
    puts "\nUsage:"
    puts "  Parse::Object.transaction do |batch|"
    puts "    # Add operations to batch"
    puts "  end"
    
  rescue => e
    puts "Error: #{e.message}"
    puts e.backtrace
  end
end