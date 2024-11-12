#!/usr/bin/env python3

#Imports
import json
import requests
import argparse
from lib.util import MonitoringPlugin
from loguru import logger
# from prometheus_client.parser import text_string_to_metric_families

#Parser
parser = argparse.ArgumentParser(description="Accesing the netbox api and returning certain metrics")
parser.add_argument('-s','--server', type=str, help='Icinga2 server', default="Netbox")
parser.add_argument('-t', '--token', type=str, help="Authentication token for the api", required=True)
parser.add_argument('--timeout', type=int, help="timeout for each request", default=10)
parser.add_argument('-d', '--devices', type=int, help='Minimum devices connected', default=364)
parser.add_argument('-v', '--virtualmachines', type=int, help='Minimum virtual machines connected', default = 201)
parser.add_argument('-i', '--ipaddresses', type=int, help='Minimum ip addresses connected', default=834)
parser.add_argument('--debug', action="store_true", default=False)
# parser.add_argument('-m', '--metrics', action="store_true", help='Get metrics')


args = parser.parse_args()
# Enable debugging
if not args.debug:
    logger.remove()

plugin = MonitoringPlugin(logger, "Netbox")


#Authentication for the netbox api
headers = {
    'Authorization': 'Token {}'.format(args.token),
    'Accept': 'application/json; indent=4',
}

def get_api_url(api_url):
    return args.server + api_url

# Function where it checks for amount of devices
def get_object(url):
    try:
        response = requests.get(url, headers=headers, timeout=args.timeout)
    except requests.exceptions.Timeout:
        plugin.setMessage(f"Could not access api for {url}, request timed out.", plugin.STATE_CRITICAL, True)
        plugin.exit()
    except:
        plugin.setMessage(f"Could not access api for {url}, request failed connect.", plugin.STATE_CRITICAL, True)
        plugin.exit()
        
    if response.status_code not in [200,201,300,301]:
        plugin.setMessage(f"Could not access api for {url}.\n Response code: {response.status_code}\n Response text: \n{response.text}", plugin.STATE_CRITICAL, True)
        plugin.exit()

    try:
        result = json.loads(response.text)
    except: 
        plugin.setMessage(f"Unable to parse json data from request {url}\n Response text: \n{response.text}", plugin.STATE_CRITICAL, True)
        plugin.exit()
    
    return result

def count_object(api_url):
    answer = get_object(get_api_url(f"{api_url}?limit=1"))
    if 'count' in answer:
        return answer["count"]
    else:
        plugin.setMessage(f"Count is missing from request to {api_url} \n Response text: \n{answer}", plugin.STATE_CRITICAL, True)
        plugin.exit()

# Something probs if statement with min value
# Devices

def check_object(api_url, name, min_count):
    nbobject = count_object(api_url)
    plugin.setPerfdata(label=name.replace(' ', '_').lower(), value=str(int(nbobject)), minimum=str(int(min_count)))
    if nbobject >= min_count:
        plugin.setMessage(f"{name.capitalize()} OK: {nbobject} found\n", plugin.STATE_OK, True)
    else: 
        plugin.setMessage(f"{name.capitalize()} FAIL: {nbobject} found is less than minimum ({min_count})\n", plugin.STATE_CRITICAL, True)

# def check_metrics():
#     metrics = get_object(f"{str(args.server).replace('/api', '')}metrics")
#     for family in text_string_to_metric_families(u"my_gauge 1.0\n"):
#         for sample in family.samples:
#             print("Name: {0} Labels: {1} Value: {2}".format(*sample))




check_object("dcim/devices/", "devices", args.devices)
check_object("ipam/ip-addresses/", "IP addresses", args.ipaddresses)
check_object("virtualization/virtual-machines/", "virtual machines", args.virtualmachines)
# check_metrics()
plugin.exit()


