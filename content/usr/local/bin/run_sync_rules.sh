#!/bin/bash

# Exit on error
set -e

# Run Sync function
run_sync_rule() {
  local rule_id=$1
  local rule_name=$2
  echo "Running sync rule ID: $rule_id - $rule_name"
  icingacli director syncrule run --id "$rule_id"
  if [ $? -eq 0 ]; then
    echo ""
  else
    echo "Sync rule $rule_name ($id) failed."
    echo ""
  fi
}

# Get all rule
all_sync_rules=$(icingacli director syncrule list | awk 'NR % 2 == 1' | awk -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $1 " " $2}')

zone_ids=()
endpoint_ids=()
group_ids=()
template_ids=()
user_ids=()
other_ids=()


# Sort them into order
while IFS= read -r line; do
  if [[ "$line" =~ ^[0-9] ]]; then  # Check if line starts with a digit
        id=$(echo "$line" | grep -o '^[0-9]*') # Extract the number at the beginning
    lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower_line" =~ zone ]]; then
      zone_ids+=("$id")
    elif [[ "$lower_line" =~ endpoint ]]; then
      endpoint_ids+=("$id")
    elif [[ "$lower_line" =~ group ]]; then
      group_ids+=("$id")
    elif [[ "$lower_line" =~ template ]]; then
      template_ids+=("$id")
    elif [[ "$lower_line" =~ user ]]; then
      user_ids+=("$id")
    else
      other_ids+=("$id")
    fi
  fi
done <<< "$all_sync_rules"

# Debug
echo zone ${zone_ids[@]}
echo endpoint ${endpoint_ids[@]}
echo group ${group_ids[@]}
echo template ${template_ids[@]}
echo user ${user_ids[@]}
echo other ${other_ids[@]}
echo ""

# Run rules in the right order
for id in "${zone_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

for id in "${endpoint_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

for id in "${group_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

for id in "${template_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

for id in "${user_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

for id in "${other_ids[@]}" ; do
        name=`echo "$all_sync_rules" | grep "^$id" | cut -f2-99 -d' '`
        run_sync_rule "$id" "$name"
done

# Deployment
echo "Deploying changes if required"
icingacli director config deploy --grace-period 20
