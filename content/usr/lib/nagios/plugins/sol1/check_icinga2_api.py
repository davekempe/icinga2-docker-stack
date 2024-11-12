#!/usr/bin/env python3
# -*- coding: utf-8 -*-
""" 
The Icinga2 api returns status with a number of leaves with each leaf coresponding to a differnet feature.
This check is designed to return as much info as possible for all the leaves if everything runs correctly 
and returns all info at the end of the run.

The exception to this is where we have a hard error such as an system exception or no returned result in 
which case we exit immediately with a critical error.

If adding a new leaf to be checked create a function that matches the leaf name (case sensitive) returned 
by the status request and append to global MESSAGE, set global EXIT_CODE during processing as required. These are 
picked up at exit for icinga to process. Only set EXIT_CODE = STATE_OK if the current state is STATE_UNKNOWN
 """
import json
import requests
import argparse
import datetime
import sys

from loguru import logger
import lib.util as util

from requests.packages import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def get_args():
    parser = argparse.ArgumentParser(description='Get status from the icinga2 api')
    parser.add_argument('--server', type=str, help='Icinga2 server', required=True)
    parser.add_argument('--port', type=str, help='Icinga2 server port', default='5665')
    parser.add_argument('--proto', type=str, help='Icinga2 server port', default='https')
    parser.add_argument('--path', type=str, help='Icinga2 server api path', default='v1/status')
    parser.add_argument('--nodes', type=str, help='Icinga2 result node names', default='IcingaApplication,IdoMysqlConnection,ApiListener,CIB')
    parser.add_argument('--features', type=str, help='Comma seperated list of features to check are enabled', default='notifications,host_checks,service_checks')
    parser.add_argument('--username', type=str, help='Icinga2 API username', required=True)
    parser.add_argument('--password', type=str, help='Icinga2 API password', required=True)
    parser.add_argument('--warnep', type=str, help='Number of endpoints not connected to trigger warning, int (5) or percent ("5%%")', default=0)
    parser.add_argument('--critep', type=str, help='Number of endpoints not connected to trigger critical, int (10) or percent ("10%%")', default=1)
    parser.add_argument('--warnah', type=int, help='Minimum number for average host checks in the last 15 minuites before triggering warning', default=1)
    parser.add_argument('--critah', type=int, help='Minimum number for average host checks in the last 15 minuites before triggering critical', default=0)
    parser.add_argument('--warnrq', type=int, help='Maximum number for remote check queue to trigger warning', default=5)
    parser.add_argument('--critrq', type=int, help='Maximum number for remote check queue to trigger critical', default=20)
    parser.add_argument('--warnqq', type=int, help='Maximum number for IDO query queue to trigger warning', default=50)
    parser.add_argument('--critqq', type=int, help='Maximum number for IDO query queue to trigger critical', default=200)
    parser.add_argument('--uptime_grace', type=int, help='Grace period after Icinga2 starts before we use check results', default=60)
    parser.add_argument('--debug', action='store_true')
    parser.add_argument('--enable-screen-debug', action="store_true")
    parser.add_argument('--log-rotate', type=str, default='1 week')
    parser.add_argument('--log-retention', type=str, default='1 month')

    args = parser.parse_args()
    return args


def keyExists(element, *keys):
    '''
    Check if *keys (nested) exists in `element` (dict).
    '''
    if not isinstance(element, dict):
        raise AttributeError('keys_exists() expects dict as first argument.')
    if len(keys) == 0:
        raise AttributeError('keys_exists() expects at least two arguments, one given.')

    _element = element
    for key in keys:
        if _element is None:
            return None
        try:
            _element = _element[key]
        except KeyError:
            return None
    return _element


def getKeyValue (element, *keys):
    v = keyExists(element, *keys)
    if v is None:
        plugin.setMessage("Missing key {}\n".format(','.join(keys)), plugin.STATE_CRITICAL, True)
    return v

# Functions to check features of the api
def IcingaApplication(leaf):
    # Check running
    program_start = getKeyValue(leaf, 'status', 'icingaapplication', 'app', 'program_start')
    if program_start == None:
        plugin.setMessage("Icinga2 doesn't appear to have started\n", plugin.STATE_CRITICAL, True)
    elif isinstance(program_start, float):
        plugin.setMessage("Icinga2 running since: {}\n".format(datetime.datetime.utcfromtimestamp(program_start)), plugin.STATE_OK, False, True)
    else:
        plugin.setMessage("Icinga2 program start ({}) doesn't appear to be a valid ephoch time\n".format(program_start), plugin.STATE_CRITICAL, True)


    # Check Features
    if len(args.features.split(',')) > 0:
        for feature in args.features.split(','):
            if getKeyValue(leaf, 'status', 'icingaapplication', 'app', str('enable_' + feature)):
                plugin.setMessage("Feature: {} enabled\n".format(feature), plugin.STATE_OK)
            else:
                plugin.setMessage("Feature: {} not enabled\n".format(feature), plugin.STATE_CRITICAL, True)

    # Check node name exists
    node_name = getKeyValue(leaf, 'status', 'icingaapplication', 'app', 'node_name')
    if node_name is None:
        plugin.setMessage("Node name: MISSING\n", plugin.STATE_CRITICAL, True)
    else:
        plugin.message = "Info: Node name: {} ({})\n".format(node_name, getKeyValue(leaf, 'status', 'icingaapplication', 'app', 'version'))

def IdoMysqlConnection(leaf):
#    "status": {
#       "idomysqlconnection": {
#           "ido-mysql": {
#               "connected": true,
#               "version"
#               "query_queue_items"
    idomysqlconnection = getKeyValue(leaf, 'status', 'idomysqlconnection')
    ido_name, ido_value = list(idomysqlconnection.items())[0]
    logger.debug(f"ido_name: {ido_name}")
    logger.debug(f"ido_value: {ido_value}")
    connected = ido_value.get('connected', False)
    if connected != True:
        plugin.setMessage("IDOMysql: Icinga2 not connected ({}) to idomysqlconnection\n".format(connected), plugin.STATE_CRITICAL, True)
    else:
        plugin.setMessage("IDOMysql: Icinga2 connected to idomysqlconnection {} ({})\n".format(ido_name, ido_value.get('version', "unknown")), plugin.STATE_OK)
    
    # query_queue_items size indicates pending queries are building up
    query_queue_items = ido_value.get('query_queue_items', None)
    msg_prefix = "IDOMysql: Query queue size {}".format(query_queue_items)
    if query_queue_items or int(query_queue_items) == 0:
        if query_queue_items > int(args.critqq):
            plugin.setCritical()
            plugin.setMessage("{} is above critical threshold ({})\n".format(msg_prefix, args.critqq), plugin.STATE_CRITICAL)
        elif query_queue_items > int(args.warnqq):
            plugin.setWarning()
            plugin.setMessage("{} is above warning threshold ({})\n".format(msg_prefix, args.warnqq), plugin.STATE_WARNING)
        else:
            plugin.setMessage("{}\n".format(msg_prefix), plugin.STATE_OK)
    else: 
        plugin.setCritical()
        plugin.setMessage("{} missing query items\n".format(msg_prefix), plugin.STATE_CRITICAL)
    


def ApiListener(leaf):
    # TODO: add perf data
#    "status": {
#        "api": {
#            "num_conn_endpoints": 4.0,
#            "num_endpoints": 4.0,
#            "num_not_conn_endpoints": 0.0,
    num_conn_endpoints = getKeyValue(leaf, 'status', 'api', 'num_conn_endpoints')
    num_endpoints = getKeyValue(leaf, 'status', 'api', 'num_endpoints')
    num_not_conn_endpoints = getKeyValue(leaf, 'status', 'api', 'num_not_conn_endpoints')
    if not isinstance(num_conn_endpoints, (int, float)) or not isinstance(num_endpoints, (int, float)) or not isinstance(num_not_conn_endpoints, (int, float)):
        plugin.setMessage("Endpoint count not a number: total - {}, connected - {}, not connected - {}\n".format(num_endpoints, num_conn_endpoints, num_not_conn_endpoints), plugin.STATE_CRITICAL, True)
    else:
        num_not_conn_endpoints = int(num_not_conn_endpoints)
        num_endpoints = int(num_endpoints)
        num_conn_endpoints = int(num_conn_endpoints)

        # If all endpoints are connected all is good
        if num_endpoints == num_conn_endpoints:
            plugin.setMessage("Endpoint: All {} endpoints currently connected\n".format(num_conn_endpoints), plugin.STATE_OK)
        else:
            msg_prefix = "Endpoint: " + str(num_not_conn_endpoints) + " of " + str(num_endpoints) + " endpoints disconnected".format(num_not_conn_endpoints, num_endpoints)
            # If the number is a percentage then get the value
            warnep = args.warnep
            critep = args.critep
            if '%' in args.warnep:
                warnep = (float(args.warnep.strip('%'))/100) * num_endpoints
            if '%' in args.critep:
                critep = (float(args.critep.strip('%'))/100) * num_endpoints
            # Test thresholds
            if num_not_conn_endpoints > int(critep):
                plugin.setCritical()
                plugin.setMessage("{} is above critical threshold ({})\n".format(msg_prefix, critep), plugin.STATE_CRITICAL)
            elif num_not_conn_endpoints > int(warnep):
                plugin.setWarning()
                plugin.setMessage("{} is above warning threshold ({})\n".format(msg_prefix, warnep), plugin.STATE_WARNING)
            else:
                plugin.setMessage("{} is below warning threshold ({})\n".format(msg_prefix, warnep), plugin.STATE_OK)

def CIB(leaf):
    # TODO: add perf data
#    "status": {
#        "active_host_checks": 24.283333333333335,
#        "active_host_checks_15min": 27887.0,
#        "active_host_checks_1min": 1457.0,

    active_host_checks_15min = getKeyValue(leaf, 'status', 'active_host_checks_15min')
    remote_check_queue = getKeyValue(leaf, 'status', 'remote_check_queue')
    current_pending_callbacks = getKeyValue(leaf, 'status', 'current_pending_callbacks')

    # These checks are trying to determine if icinga is running but there is a problem meaning the expected workload isn't being met

    # Active host checks run in last 15 minuites
    # TODO: allow percentage values for thresholds here based on (num_hosts_up + num_hosts_down)
    if not isinstance(active_host_checks_15min, (int, float)):
        plugin.setMessage("CIB: Active host check 15 min average is not a number ({})\n".format(active_host_checks_15min), plugin.STATE_CRITICAL, True)
    else:
        active_host_checks_15min = int(active_host_checks_15min)
        if active_host_checks_15min < args.critah:
            plugin.setCritical()   
            plugin.setMessage("CIB: Active host check 15 min average ({}) is less than crit threshold ({})\n".format(active_host_checks_15min, args.critah), plugin.STATE_CRITICAL)
        elif active_host_checks_15min < args.warnah:
            plugin.setWarning()
            plugin.setMessage("CIB: Active host check 15 min average ({}) is less than warn threshold ({})\n".format(active_host_checks_15min, args.warnah), plugin.STATE_WARNING)
        else:
            plugin.setMessage("CIB: Active host check 15 min average ({})\n".format(active_host_checks_15min), plugin.STATE_OK, True)
            
    # Remote check queue size
    if not isinstance(remote_check_queue, (int, float)):
        plugin.setMessage("CIB: Remote check queue is not a number ({})\n".format(active_host_checks_15min), plugin.STATE_CRITICAL, True)
    else:
        remote_check_queue = int(remote_check_queue)
        if remote_check_queue > args.critrq:
            plugin.setCritical()   
            plugin.setMessage("CIB: Remote check queue ({}) is less than crit threshold ({})\n".format(remote_check_queue, args.critrq), plugin.STATE_CRITICAL)
        elif remote_check_queue > args.warnrq:
            plugin.setWarning()
            plugin.setMessage("CIB: Remote check queue ({}) is less than warn threshold ({})\n".format(remote_check_queue, args.warnrq), plugin.STATE_WARNING)
        else:
            plugin.setMessage("CIB: Remote check queue ({})\n".format(remote_check_queue), plugin.STATE_OK)


    # TODO: current_pending_callbacks may also deviate under adverse conditions, no test yet just a value in output
    plugin.message = "Info: CIB: Current pending callbacks ({})\n".format(current_pending_callbacks)

# Get args
args = get_args()

# Init logging
util.init_logging(debug=args.debug, enableScreenDebug=args.enable_screen_debug, logFile='/var/log/icinga2/check_icinga2_api.log', logRotate=args.log_rotate, logRetention=args.log_retention)
logger.info("Processing check_icinga2_api with args [{}]".format(args))

# Init plugin
plugin = util.MonitoringPlugin(logger, "Icinga2 API {}".format(args.nodes))

url = args.proto + '://' + args.server + ':' + args.port + '/' + args.path
headers = {
    'Accept': 'application/json ; indent=4',
    'X-HTTP-Method-Override': 'GET'
}

try:
    result = requests.get(url, headers, auth=(args.username, args.password), verify=False)
    logger.info("Url: {}".format(result.url))
    logger.info("Return status: {}".format(result.status_code))
    logger.debug("Text: {}".format(result.text))
except requests.exceptions.RequestException as e:
    logger.error("{0} requests.get failed with exception\n{1}\n".format(args.proto, e))
    plugin.setMessage("{0} requests.get failed with exception\n{1}\n".format(args.proto, e), plugin.STATE_CRITICAL, True)
    plugin.exit()


# make sure we get a http result we like
if result.status_code in [200, 301, 302]:
    try: 
        jresult = result.json()
    except:
        logger.error("Result does not appear to be valid json\n{}".format(result.text))
        plugin.setMessage("Result does not appear to be valid json\n{}".format(result.text), plugin.STATE_CRITICAL, True)
        plugin.exit()

    if args.debug:
        logger.debug(json.dumps(jresult, indent=4, sort_keys=True))

    # Uptime determines status so get it first
    icinga_uptime = None

    # make sure we get api data in the result
    processed_nodes = []
    for leaf in jresult['results']:
        name = getKeyValue(leaf, 'name')
        logger.debug(f"leaf name: {name}")
        try:
            if name == "CIB":
                icinga_uptime = int(getKeyValue(leaf, 'status', 'uptime'))
        except Exception as e:
            logger.error(f"Error getting uptime: {e}")
        if name in args.nodes.split(','):
            # Now test the api data
            eval(name + '(leaf)')
            processed_nodes.append(name)

    if set(processed_nodes) != set(args.nodes.split(',')):
        logger.error("Processed nodes ({processed}) don't match required nodes ({required})\n".format(processed=','.join(processed_nodes), required=args.nodes))
        plugin.setMessage("Processed nodes ({processed}) don't match required nodes ({required})\n".format(processed=','.join(processed_nodes), required=args.nodes), plugin.STATE_CRITICAL, True)
else:
    logger.error("Invalid return code ({}) from http request to API\n{}".format(result.status_code, result.text))
    plugin.setMessage("Invalid return code ({}) from http request to API\n{}".format(result.status_code, result.text), plugin.STATE_CRITICAL, True)

if icinga_uptime is None: 
    plugin.message = "Info: CIB Uptime is missing"
    logger.warning("CIB Uptime is missing")
elif icinga_uptime < args.uptime_grace:
    plugin.message = f"Info: CIB Uptime is {icinga_uptime}, setting check state to WARNING as Icinga may not have been running long enough to generate accurate results based on check uptime_grace {args.uptime_grace}."
    plugin.state = plugin.STATE_WARNING
else:
    plugin.message = f"Info: CIB Uptime is {icinga_uptime}"

plugin.setOk()
plugin.exit()
