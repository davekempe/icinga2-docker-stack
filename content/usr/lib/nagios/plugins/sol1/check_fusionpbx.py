#!/usr/bin/env python3
import humanize
import subprocess
import re
import xmltodict
import csv

from datetime import datetime, timedelta

import lib.jsonarg as argparse
from lib.util import init_logging, MonitoringPlugin
from lib.icinga import Icinga
from loguru import logger

def get_args():
    # Initialize the argument parser
    parser = argparse.ArgumentParser(description='Check Fusion PBX with fs_cli.')

    # Debug settings
    parser.add_argument('--debug', action="store_true")
    parser.add_argument('--enable-screen-debug', action="store_true")
    parser.add_argument('--log-rotate', type=str, default='1 day')
    parser.add_argument('--log-retention', type=str, default='3 days')

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    parserStatus = subparser.add_parser("Status", help="Return the status, uptime and version.")

    parserGateway = subparser.add_parser("Gateway", help="Return the state of a running gateway.")
    parserGateway.add_argument('--id', type=str, help="Gateway ID in FreePBX")

    parserGatewaysMonitoring = subparser.add_parser("GatewaysMonitored", help="Meta check to see what gateways are being monitored.")
    parserGatewaysMonitoring.add_argument('--exclude', action='append', type=str, help="ID's to exclude")
    parserGatewaysMonitoring.add_argument('--icinga-url', type=str, help="URL to Icinga API", required=True)
    parserGatewaysMonitoring.add_argument('--icinga-user', type=str, help="Username for Icinga API", required=True)
    parserGatewaysMonitoring.add_argument('--icinga-password', type=str, help="Password to Icinga API", required=True)
    parserGatewaysMonitoring.add_argument('--service-prefix', type=str, help='Prefix used in the Icinga Service, used to find the services and extract the Org names from the service name', required=True)

    parserRegistrations = subparser.add_parser("Registrations", help="List registered handsets.")
    parserRegistrations.add_argument('--domain', type=str, help="Domain to filter on")
    parserRegistrations.add_argument('--minimum', type=int, help="Minimum number of registrations", default=0)

    args = parser.parse_args()
    return args

class fusionPBX:
    def __init__(self, _args):
        self._args = _args
        self._status = {}        
        self._gateway = []
        self._registrations = []
        self.id = None

    @staticmethod
    def _getCommand(command):
        output = None
        # make the command list if it isn't a list already
        if not isinstance(command, list):
            command = str(command).split(' ')
        logger.debug(command)
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            output = result.stdout
        else:
            plugin.setMessage(f"Command {command} failed with \n{result.stdout}", plugin.STATE_CRITICAL, True)
            logger.error(f"Command {command} failed with \n{result.stdout}")
            plugin.exit()
        logger.debug(output)
        return output

    @property
    def status(self):
        if not self._status:
            result = {
                "uptime": None,
                "update": None,
                "version": None,
                "status": None
            }
            output = self._getCommand(['fs_cli', '-x', 'status'])

            # Get the uptime
            try:
                # Regular expression to match and extract numbers before each time unit
                uptime_matches = {
                    "years": re.search(r"(\d+) year", output),
                    "days": re.search(r"(\d+) day", output),
                    "hours": re.search(r"(\d+) hour", output),
                    "minutes": re.search(r"(\d+) minute", output),
                    "seconds": re.search(r"(\d+) second", output),
                    "milliseconds": re.search(r"(\d+) millisecond", output)
                }

                logger.debug(uptime_matches)

                # Extract matched values or use default 0
                uptime_values = {key: int(match.group(1)) if match else 0 for key, match in uptime_matches.items()}
                logger.debug(uptime_values)

                # Calculate the total timedelta, converting milliseconds and microseconds to seconds
                delta = timedelta(
                    days=uptime_values["days"] + uptime_values["years"] * 365,  # Assuming a year has 365 days, this can be adjusted if needed.
                    hours=uptime_values["hours"],
                    minutes=uptime_values["minutes"],
                    seconds=uptime_values["seconds"] + uptime_values["milliseconds"] / 1000
                )

                result['uptime'] = delta
                result['update'] = datetime.now() - delta
            except Exception as e: 
                logger.error(f"Error processing uptime: {e}")

            try:
                match = re.search(r'\((.*Version.*)\)', output)
                if match:
                    result["version"] = match.group(1)
            except Exception as e: 
                logger.error(f"Error processing version: {e}")
            try:
                match = re.search(r'FreeSWITCH .* is (.*)', output)
                if match:
                    result["status"] = match.group(1)
            except Exception as e: 
                logger.error(f"Error processing status: {e}")

            self._status = result
            logger.debug(self._status)
        return self._status

    @property
    def gateways(self):
        if not self._gateway:
            command = ['fs_cli', '-x', 'sofia xmlstatus gateway']
            if self.id:
                command = ['fs_cli', '-x', f'sofia xmlstatus gateway {self.id}']
            result = []
            output = self._getCommand(command)
            try:
                result = xmltodict.parse(output)
            except Exception as e:
                logger.error(f"Error getting gateway xml: {e}")

            if 'gateways' in result:
                self._gateway = result['gateways']['gateway']
            elif 'gateway' in result:
                self._gateway = [result['gateway']]
            logger.debug(self._gateway)
        return self._gateway

    @property
    def registrations(self):
        if not self._registrations:
            command = ['fs_cli', '-x', 'show registrations']
            output = self._getCommand(command)
            try:
                reader = csv.DictReader(output.splitlines())
                self._registrations = [row for row in reader]
            except Exception as e:
                logger.error(f"Error getting regsitrations csv: {e}")
            logger.debug(self._registrations)
        return self._registrations

    # status, version and uptime
    def Status(self):
        plugin.message = f"Info: Uptime is {humanize.precisedelta(self.status.get('uptime', ''))} ({self.status.get('update', None).strftime('%d/%m/%y %H:%M:%S')})\n"
        plugin.message = f"Version: {self.status.get('version', '')}\n"
        plugin.message = f"Status: {self.status.get('status', '')}\n"
        plugin.setOk()

    # one gateway status
    def Gateway(self):
        if hasattr(self._args, 'id'):
            self.id = self._args.id
        
        for gateway in self.gateways:
            plugin.message = f"\nInfo: ID - {gateway.get('name', '')}\n"

            if gateway.get('state', '') in ['REGED']:
                plugin.setMessage(f"State - {gateway.get('state', '')}\n", plugin.STATE_OK, True)
            else:
                plugin.setMessage(f"State - {gateway.get('state', '')}\n", plugin.STATE_CRITICAL, True)

            if gateway.get('status', '') in ['UP']:
                plugin.setMessage(f"Status - {gateway.get('status', '')}\n", plugin.STATE_OK, True)
            else:
                plugin.setMessage(f"Status - {gateway.get('status', '')}\n", plugin.STATE_CRITICAL, True)

            plugin.message = f"Info: Extension - {gateway.get('exten', '')}\n"
            plugin.message = f"Info: To - {gateway.get('to', '')}\n"
            plugin.message = f"Info: From - {gateway.get('from', '')}\n"
            plugin.message = f"Info: Contact - {gateway.get('contact', '')}\n"
            

    def GatewaysMonitored(self):
        icinga = Icinga(self._args.icinga_url, user=self._args.icinga_user, password=self._args.icinga_password)
        icinga_checks = icinga.getCheckResults('services', f'match("{self._args.service_prefix}*", service.display_name)')
        if not icinga_checks:
            plugin.setMessage(f"No Icinga services found matching {self._args.service_prefix}*", plugin.STATE_CRITICAL, True)
            plugin.exit()
        logger.debug(icinga_checks)

        found_gateways = []
        missing_gateways = []
        excluded_gateways = []
        if self._args.exclude:
            excluded_gateways = self._args.exclude
        for gateway in self.gateways:
            if gateway.get('name', 'no gateway name') not in excluded_gateways:
                missing = True
                for check in icinga_checks:
                    if gateway.get('name', 'no gateway name') in check.get('attrs', {}).get('name', '!No name found'):
                        found_gateways.append(gateway.get('name', ''))
                        missing = False
                if missing:
                    missing_gateways.append(gateway.get('name', ''))

        for missing in missing_gateways:
            plugin.setMessage(f"Missing gateway check for {missing}\n", plugin.STATE_CRITICAL, True)        
        if found_gateways == 0:
            plugin.setMessage(f"No gateway checks found\n", plugin.STATE_CRITICAL, True)        
        for found in found_gateways:
            plugin.setMessage(f"Found gateway check for {found}\n", plugin.STATE_OK, True)        
        for excluded in excluded_gateways:
            plugin.message = f"Info: Exclude gateway check for {excluded}\n"
        
        plugin.perfdata('missing', len(missing_gateways))
        plugin.perfdata('found', len(found_gateways))
        plugin.perfdata('excluded', len(excluded_gateways))
                    
    def Registrations(self):
        matches = {}
        for registration in self.registrations:
            if 'realm' in registration and registration['realm'] is not None:
                if registration['realm'] not in matches:
                    matches[registration['realm']] = []
                matches[registration['realm']].append(registration)
            else:
                if 'no realm found' not in matches:
                    matches['no realm found'] = []    
                matches['no realm found'].append(registration)
        logger.debug(matches)

        if self._args.domain:
            plugin.message = f"\nRegistrations for {self._args.domain}\n"
            count = len(matches.get(self._args.domain, []))
        else:
            plugin.message = f"\nAll Registrations\n"
            count = len(self.registrations)

        if count < self._args.minimum:
            plugin.setMessage(f"Found {count} registrations which is less than minimum {self._args.minimum}\n", plugin.STATE_CRITICAL, True)
        else:
            plugin.setMessage(f"Found {count} registrations which is meets the minimum {self._args.minimum}\n", plugin.STATE_OK, True)

        plugin.setPerfdata('total', len(self.registrations))
        if self._args.domain:
            for registration in matches.get(self._args.domain, []):
                plugin.message = f"\nUser - {registration['reg_user']}, IP - {registration['network_ip']}"
                plugin.setPerfdata(self._args.domain, count)
        else:
            for domain in matches.keys():
                plugin.message = f"\nRegistrations for {domain}\n"
                for registration in matches[domain]:
                    plugin.message = f"User - {registration['reg_user']}, IP - {registration['network_ip']}\n"
                    plugin.setPerfdata(domain, len(matches[domain]))


if __name__ == "__main__":
    # Init args
    args = get_args()

    # Init logging
    init_logging(debug=args.debug, enableScreenDebug=args.enable_screen_debug, logFile='/var/log/icinga2/check_fusionPBX.log', logRotate=args.log_rotate, logRetention=args.log_retention)
    logger.info("Processing Fusion PBX check with args [{}]".format(args))

    # Init plugin
    plugin = MonitoringPlugin(logger, args.mode)

    # Run and exit
    fusion_pbx = fusionPBX(args)
    logger.debug("Running check for {}".format(args.mode))
    eval('fusion_pbx.{}()'.format(args.mode))
    plugin.exit()