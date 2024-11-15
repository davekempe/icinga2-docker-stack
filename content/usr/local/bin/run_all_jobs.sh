#!/bin/bash

# Exit on error
set -e

# Function to run a sync rule
run_sync_rule() {
  local rule_id=$1
  local rule_name=$2
  echo "Running sync rule ID: $rule_id - $rule_name"
  icingacli director syncrule run --id "$rule_id"
  if [ $? -eq 0 ]; then
    echo "Sync rule $rule_name completed successfully."
  else
    echo "Sync rule $rule_name failed."
  fi
}

# Fetch all sync rules, cleaning out every second line
all_sync_rules=$(icingacli director syncrule list | awk 'NR % 2 == 1' | awk -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 " " $2}')

# Exclude Contact rules and handle them separately
contact_rules=()
other_rules=()

while IFS= read -r line; do
  if [[ "$line" == *"Contacts"* ]]; then
    contact_rules+=("$line")
  else
    other_rules+=("$line")
  fi
done <<< "$all_sync_rules"

# Define the execution order based on NetBox data model dependencies for non-contact rules
declare -a ordered_rules=(
  "Regions"             # Parent regions first
  "Sites"               # Then sites
  "Device Roles"        # Device roles before hosts
  "Platforms"           # Platforms and types before devices
  "Platform Families"
  "Platform Types"
  "Clusters"            # Clusters and their types/groups
  "Cluster Groups"
  "Cluster Types"
  "Tags"                # Tags can come later
  "Default Virtual Machines" # Finally, virtual machines and devices
  "Default Devices"
)

# Run non-contact sync rules in the specified order
for rule_keyword in "${ordered_rules[@]}"; do
  echo "Processing sync rules matching: $rule_keyword"
  for line in "${other_rules[@]}"; do
    rule_id=$(echo "$line" | awk '{print $1}')
    rule_name=$(echo "$line" | cut -d' ' -f2-)
    if [[ "$rule_name" == *"$rule_keyword"* ]]; then
      run_sync_rule "$rule_id" "$rule_name"
    fi
  done
done

# Process Contact rules in the specified order
declare -a contact_order=(
  "Netbox Contacts -> Users"
  "Netbox Contacts Enhanced Email (Host Assignment) -> Notification Apply"
  "Netbox Contacts Enhanced Email (Service Assignment) -> Notification Apply"
  "Netbox Contacts Pushover (Host Assignment) -> Notification Apply"
  "Netbox Contacts Pushover (Service Assignment) -> Notification Apply"
)

echo "Processing Contact sync rules in defined order:"
for contact_name in "${contact_order[@]}"; do
  for line in "${contact_rules[@]}"; do
    rule_id=$(echo "$line" | awk '{print $1}')
    rule_name=$(echo "$line" | cut -d' ' -f2-)
    if [[ "$rule_name" == "$contact_name" ]]; then
      run_sync_rule "$rule_id" "$rule_name"
    fi
  done
done

echo "All sync rules processed."
