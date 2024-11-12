#!/usr/bin/env python3

from email.policy import default
from logging import warning
from os import major, minor
import re
import lib.jsonarg as argparse

from lib.util import init_logging, MonitoringPlugin
from loguru import logger


import requests
from requests.auth import HTTPBasicAuth
from json import loads

import urllib3
# because certificates cannot be verified
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

ALARM_LEVELS = [ "information", "warning", "minor", "major", "critical" ]

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Use the Titan API to get check results and return a different check result")

    # Titan API settings
    parser.add_argument('-s', '--server', type=str, help='Titan API server url, eg: http://titan.example.com', required=True)
    parser.add_argument('-u', '--username', type=str, help='Titan API username', required=True)
    parser.add_argument('-p', '--password', type=str, help='Titan API password', required=True)
    
    # Debug settings
    parser.add_argument('--debug', action="store_true")
    parser.add_argument('--enable-screen-debug', action="store_true")
    parser.add_argument('--log-rotate', type=str, default='1 day')
    parser.add_argument('--log-retention', type=str, default='3 days')

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # CPU Load
    parserCPU = subparser.add_parser("cpu", help="Test cpu load")
    parserCPU.add_argument('--warning', type=int, help='Threshold for warning state, number value only', default=5)
    parserCPU.add_argument('--critical', type=int, help='Threshold for critical state, number value only', default=10)

    # Memory Usage
    parserMemory = subparser.add_parser("memory", help="Test memory usage.")
    parserCPU.add_argument('--warning', type=int, help='Threshold for warning state, number value in MB (10000) or percentage of total (80%)', default='80%')
    parserCPU.add_argument('--critical', type=int, help='Threshold for critical state, number value in MB (20000) or percentage of total (90%)', default='90%')

    # Status
    parserStatus = subparser.add_parser("status", help="Return the status of components.")
    parserStatus.add_argument('--required', type=str, help='Comma seperated list of compents that are required', required=True)

    # Alarms
    parserAlarms = subparser.add_parser("Alarms", help="Return alarms.")
    parserAlarms.add_argument('--open', action="store_false", help='Returns open alarms only (default) or all alarms', default=True)
    parserAlarms.add_argument('--level', type=str, default='critical', const='critical', nargs='?', choices=ALARM_LEVELS, help='Level of alarms to process, return chosen level and above')

    args = parser.parse_args(argvals)

    return args

class Titan:
    def __init__(self, server, user, password, _args):
        logger.info(f"init Titan object")
        self.server = server
        self.__user = user
        self.__password = password
        self._args = args
        self.__headers = {
            "Accept": "application/json",
            "Content-Type": "application/json"
        }
        logger.debug(f"Titan object properties: server={self.server}, user={self.__user}")

    def get(self, url, decode_json = False):
        return self.__request('GET', url, decode_json)

    def post(self, url, payload, decode_json = False):
        return self.__request('POST', url, payload, decode_json)
 
    def __request(self, reqtype, url, payload = None, decode_json: bool = True):
        try:
            logger.debug(f"Request to {url} using {reqtype}\n")
            if reqtype == 'GET':
                response = requests.get(url=url, headers=self.__headers, auth = HTTPBasicAuth(self.__user, self.__password), verify=False)
            elif reqtype == 'POST':
                response = requests.post(url=url, headers=self.__headers, auth = HTTPBasicAuth(self.__user, self.__password), json=payload, verify=False)
            else:
                logger.error(f"Titan request not GET or POST, this shouldn't happen.")
            logger.debug(f"Titan {reqtype} response {response}")
        except Exception as e:
            logger.error(f"Titan request error for {url}: {e}")

        # If we don't get a good error message then add a error but still return the result
        if response.status_code not in [200,201,202,300,301]:
            logger.error(f"Titan request bad return code for {url}. Response code: {response.status_code}\n Response text: \n{response.text}")

        try:
            if decode_json:
                result = loads(response.text)
            else:
                result = response.text
        except Exception as e:
            result = response.text
            logger.error(f"Titan request parse error for {url}: {e}")
        logger.info(f"Titan {reqtype} response: {response}")
        return result

    # Helper methods
    def _makeURL(self, path):
        return f"{self.server}/api/v1/{path}"

    # API request methods
    def _getCPU(self):
        return self.get(self._makeURL('system/information/cpu'), True)

    def _getMemory(self):
        return self.get(self._makeURL('system/information/memory'), True)

    def _getStatus(self):
        return self.get(self._makeURL('system/information/status'), True)

    def _getVersion(self):
        return self.get(self._makeURL('system/information/version'), True)

    def _getAlarms(self):
        return self.get(self._makeURL('alarmsmngt/alarms'), True)

    # Check methods
    def cpu(self):
        cpu_info = self._getCPU()

        for key in ['CPUType', 'NBCore', 'CPUFrequency', 'Virtualization', 'CPULoad']:
            if key in cpu_info:
                if key == 'CPULoad':
                    if self._args.critical < int(cpu_info[key]):
                        cpu_state = plugin.STATE_CRITICAL
                    elif self._args.warning < int(cpu_info[key]):
                        cpu_state = plugin.STATE_WARNING
                    else:
                        cpu_state = plugin.STATE_OK
                    plugin.setMessage(f"{key}: {cpu_info[key]}\n", cpu_state, True)
                else:
                    plugin.message = f"Info: {key}: {cpu_info[key]}\n"                    
            else:
                if key == 'CPULoad':
                    plugin.setMessage(f"{key} key is missing from CPU Information API call\n", plugin.STATE_CRITICAL, True)
                else:
                    plugin.message = f"Info: Expected {key} key is missing from CPU Information API call\n"                    


    def memory(self):
        memory_info = self._getMemory()

        if 'MemorySize' in memory_info:
            plugin.message = f"Info: Total memory: {memory_info['MemorySize']}\n"
        else: 
            plugin.message = f"Info: Expected MemorySize key is missing from Memory Information API call\n"                    
            if self._args.warning.endswith('%') or self._args.critical.endswith('%'):
                plugin.setMessage(f"Unable to calculate usage with MemorySize key is missing.", plugin.STATE_CRITICAL, True)
                plugin.exit()

        if 'MemoryUsage' in memory_info:
            warn_threshold = self._args.warning
            crit_threshold = self._args.critical
            if self._args.warning.endswith('%') or self._args.critical.endswith('%'):
                warn_threshold = int(memory_info['MemorySize']) * ( int(self._args.warning.replace('%','')) / 100 )
                crit_threshold = int(memory_info['MemorySize']) * ( int(self._args.critical.replace('%','')) / 100 )
            
            if crit_threshold > int(memory_info['MemoryUsage']):
                memory_state = plugin.STATE_CRITICAL
            elif warn_threshold > int(memory_info['MemoryUsage']):
                memory_state = plugin.STATE_WARNING
            else:
                memory_state = plugin.STATE_OK
            plugin.setMessage(f"Used Memory: {memory_info['MemoryUsage']}\n", memory_state, True)
        else: 
            plugin.setMessage(f"Info: Expected MemoryUsage key is missing from Memory Information API call\n", plugin.STATE_CRITICAL, True)

            

    def status(self):
        # status = self._getStatus()
        # version = self._getVersion()
        plugin.message = "This does nothing at the moment, perhaps you'd like to add it yourself."

    def alarms(self):
        alarms = self._getAlarms()

        required_fields = ['Level', '_open']

        for alarm in alarms:
            # If we can't find required fields skip
            required_missing = False
            for field in required_fields:
                if field not in alarm:
                    plugin.setMessage(f"Missing required field {field} on alarm {alarm.get('UID', 'unknown')}\n", plugin.STATE_WARNING, True)
                    logger.warning(f"Missing required field {field} for alarm:\n{alarm}")
                    required_missing = True
                    break
            if required_missing:
                continue
            
            # If we can't find a matching alarm level skip
            if not alarm['Level'] in ALARM_LEVELS:
                    plugin.setMessage(f"Unable to match alarm level {alarm['Level']} on alarm {alarm.get('UID', 'unknown')}\n", plugin.STATE_WARNING, True)
                    logger.warning(f"Unable to match alarm level {alarm['Level']} for alarm:\n{alarm}")
                    continue
            
            # Alarms we care about
            if bool(alarm['_open']) == self._args.open and ALARM_LEVELS.index(alarm['Level']) >= ALARM_LEVELS.index(self._args.level):
                plugin.setMessage(f"Alarm UID {alarm.get('UID', 'unknown')} of type {alarm.get('Type', '')} is {alarm['_open']} and {alarm['Level']}\n")
                plugin.message = f"Name: {alarm.get('Name', 'missing')}, Service: {alarm.get('Informations', {}).get('ServiceName', 'missing')}\n"
                plugin.message = f"Description: {alarm.get('Description', 'missing')}\n"     


# Init args
args = get_args()

# Init logging
init_logging(debug=args.debug, enableScreenDebug=args.enable_screen_debug, logFile='/var/log/icinga2/check_titan.log', logRotate=args.log_rotate, logRetention=args.log_retention)
logger.info("Processing Titan check with args [{}]".format(args))

# Init plugin
plugin = MonitoringPlugin(logger, args.mode)

# Run and exit
titan = Titan(args.server, args.username, args.password, args)
logger.debug("Running check for {}".format(args.mode))
eval('titan.{}()'.format(args.mode))
plugin.exit()