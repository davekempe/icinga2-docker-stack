#!/usr/bin/python3
from sol1_monitoring_plugins_lib import MonitoringPlugin     #, initLogging, initLoggingArgparse
from loguru import logger
import os

class InitArgs:
    import argparse
    parser = argparse.ArgumentParser(description="Use the Icinga API to get check results and return a different check result")

    # Icinga API settings
    parser.add_argument('--hostname', type=str, help='Expected hostname, will return OK for partial match', required=False)
    # parser.add_argument('--address', type=str, help='', required=True)
    
    # Debug and Logging settings
    # initLoggingArgparse(parser)

    @classmethod
    def parse_args(cls, _args = None):
        # Parse the arguments
        args = cls.parser.parse_args(_args)
        
        # Add any post parsing validation here
        return args

def checkHostname():
    hostname = os.uname().nodename
    if args.hostname:
        if args.hostname.lower() == str(hostname).lower():
            plugin.setMessage(f"Hostname '{hostname}' exactly matches expected name '{args.hostname}'", plugin.STATE_OK, True)
        elif args.hostname.lower() in str(hostname).lower() or args.hostname.lower().split('.')[0] in str(hostname).lower():
            plugin.setMessage(f"Hostname '{hostname}' partially matches expected name '{args.hostname}'", plugin.STATE_OK, True)
        else:
            plugin.setMessage(f"Hostname '{hostname}' doesn't match expected name '{args.hostname}'", plugin.STATE_WARNING, True)
    else:
        plugin.message = f"Hostname is '{hostname}'"


if __name__ == "__main__":
    # Init args
    args = InitArgs().parse_args()

    # Init logging
    logger.remove()
    # initLogging(debug=args.debug, enable_screen_debug=args.enable_screen_debug, log_file='/var/log/icinga2/check_whoami.log', log_rotate=args.log_rotate, log_retention=args.log_retention)
    # logger.info("Processing Who I am check with args [{}]".format(args))

    # Init plugin
    plugin = MonitoringPlugin()

    # Run and exit
    checkHostname()
    
    plugin.setOk()
    plugin.exit()


