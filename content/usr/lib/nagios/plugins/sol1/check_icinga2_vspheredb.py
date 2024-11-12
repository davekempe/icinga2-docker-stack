#!/usr/bin/env python3

import subprocess
import re

from lib.icinga import Icinga
from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse

from loguru import logger

# Class to init the args so we can load this check as a library and get the arguments without parsing to create a basket
class InitArgs:
    import argparse
    parser = argparse.ArgumentParser(description="Use the Icinga API to get check results and return a different check result")

    # Icinga API settings
    parser.add_argument('--server', type=str, help='Icinga API server url including port, eg: https://icinga.example.com:5665', required=True)
    parser.add_argument('--username', type=str, help='Icinga API username', required=True)
    parser.add_argument('--password', type=str, help='Icinga API password', required=True)
    
    # Debug and Logging settings
    initLoggingArgparse(parser)

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # Passive Hosts
    parserStatus = subparser.add_parser("passivehosts", help="Find all services matching the filter and return passive results from vsphere for their hosts to each service")
    parserStatus.add_argument('--filter', type=str, help='Filter for checks to process', required=True)

    @classmethod
    def parse_args(cls, _args = None):
        # Parse the arguments
        args = cls.parser.parse_args(_args)
        
        # Add any post parsing validation here
        return args


class IcingaChecker(Icinga):
    def __init__(self, server, user, password, _args):
        self._args = _args
        super().__init__(server, user, password)  
        logger.debug(f"Class args: {self._args}")
    
    def passivehosts(self):
        # Get checks
        checks = self.getCheckResults('services', self._args.filter)
        if not checks:
            plugin.setMessage(f"No services found matching filter: {self._args.filter}", plugin.STATE_WARNING, True)
            plugin.exit()

        try:
            icingacli = IcingaCli()
            hosts_worked = []
            hosts_failed = []
            for check in checks:
                host_name = check.get('attrs', {}).get('host_name', "")
                service_name = check.get('attrs', {}).get('name', "")
                if host_name and service_name:
                    try:
                        result, result_success = icingacli.vSphereDBVM(host_name)
                        state, message, performance_data = result.exit(do_exit = False)
                        if result_success:
                            logger.debug(f"host={host_name}, service={service_name}, status={state}, message={message}, perfdata={performance_data}")
                            self.processServiceCheckResult(host=host_name, service=service_name, status=state, message=message, perfdata=performance_data)
                            hosts_worked.append(host_name)
                        else:
                            hosts_failed.append(host_name)
                    except Exception as e:
                        hosts_failed.append(host_name)
                else:
                    plugin.setMessage(f"Unable to determine host and service name for {check.get('attrs', {}).get('__name', 'Unknown')}\n")
                    logger.warning(f"Unable to determine host and service name for {check}")
            plugin.message = f"Passive updates for services on hosts matching filter {self._args.filter}\n"
            if hosts_worked:
                plugin.setMessage(f"Successful: {', '.join(hosts_worked)}\n", plugin.STATE_OK, True)
            if hosts_failed:
                plugin.setMessage(f"Failed: {', '.join(hosts_failed)}\n", plugin.STATE_CRITICAL, True)
        except Exception as e:
            plugin.setMessage("Error processing passive hosts:\n{e}\n", plugin.STATE_CRITICAL, True)
            logger.error("Error processing passive hosts:\n{e}\n")
            plugin.exit()

class IcingaCli:
    def __init__(self):
        pass

    def vSphereDBVM(self, vm_name):
        command = ["icingacli", "vspheredb", "check", "vm", "--name", vm_name]
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=True)
            logger.debug(result)
            return (self.parseOutput(result.stdout, "vSphereDB passive"), True)
        except subprocess.CalledProcessError as e:
            return (f"Command failed with error: {e}", False)

    def parseOutput(self, output, type = ""):
        _plugin = MonitoringPlugin(type)
        lines = output.split('\n')
        for line in lines:
            if '[OK]' in line:
                _plugin.setOk()
            elif '[WARNING]' in line:
                _plugin.setWarning()
            elif '[CRITICAL]' in line:
                _plugin.setCritical()
            _plugin.message = f"{line}\n"                     
        return _plugin

if __name__ == "__main__":
    # Init args
    args = InitArgs().parse_args()

    # Init logging
    initLogging(debug=args.debug, enable_screen_debug=args.enable_screen_debug, log_file='/var/log/icinga2/check_icinga_vspheredb.log', log_rotate=args.log_rotate, log_retention=args.log_retention)
    logger.info("Processing Hybrid monitoring checks check with args [{}]".format(args))

    # Init plugin
    plugin = MonitoringPlugin(args.mode)

    # Run and exit
    icinga = IcingaChecker(args.server, args.username, args.password, args)
    logger.debug("Running check for {}".format(args.mode))
    eval('icinga.{}()'.format(args.mode))
    plugin.exit()
