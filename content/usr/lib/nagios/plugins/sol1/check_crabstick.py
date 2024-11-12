#!/usr/bin/env python3.9

#Imports
import argparse

from loguru import logger
import lib.util as util
from lib.api import SimpleAPI
from datetime import datetime
from dateutil.parser import parse

# http debugging
#import logging
#from http.client import HTTPConnection
#HTTPConnection.debuglevel = 1
#logging.basicConfig
#logging.getLogger().setLevel(logging.DEBUG)
#requests_log = logging.getLogger("requests.pachild_keyages.urllib3")
#requests_log.setLevel(logging.DEBUG)
#requests_log.propagate = True

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Use the crabstick api and return metrics")

    # ICONTROL server
    parser.add_argument('-s', '--server', type=str, help='crabstick server url including port, eg: http://example.com:8076', required=True)

    parser.add_argument('--cacheage', type=int, help='Maximum age for cached ICONTROL API data (in seconds)', required=False, default=290)

    parser.add_argument('--debug', action="store_true")
    parser.add_argument('--enable-screen-debug', action="store_true")
    parser.add_argument('--log-rotate', type=str, default='1 week')
    parser.add_argument('--log-retention', type=str, default='1 month')

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    parserStatus = subparser.add_parser("status", help="check Status")
    parserStatus.add_argument('--status-max-age', type=str, help='Time in seconds that the status api should have been last accessed', required=False)

    return parser.parse_args(argvals)


class Crabstick(SimpleAPI):
    def  __init__(self, server, args):
        self.server = server
        self._args = args
        super().__init__(self.server)      

    def status(self):
        try:
            status = self.get("/status")
        except Exception as e:
            logger.error("Error getting crabstick status from {}: {}".format(self.server, e))
            plugin.setMessage("Failed to get crabstick status.\n", plugin.STATE_CRITICAL, True)
            plugin.exit()

        logger.debug("Status is {}".format(status))
        if status.get('name', None) == 'crabstick':
            plugin.setMessage("API name 'crabstick' found.\n", plugin.STATE_OK, True)
        else:
            plugin.setMessage("API name 'crabstick' not found, got {} instead.\n".format(status.get('name', None)), plugin.STATE_CRITICAL, True)

        if status.get('version', None) == status.get('version_lastrun', None):
            plugin.setMessage("Running server version ({}) matches deployed version.\n".format(status.get('version', None)), plugin.STATE_OK, True)
        else:
            plugin.setMessage("Running server version ({}) does not match deployed version ({}).\n".format(status.get('version', None), status.get('version_lastrun', None)), plugin.STATE_CRITICAL, True)

        plugin.message = "Info: Crabstick server start time {}.\n".format(status.get('server_start', None))
        current_epoch = datetime.now().timestamp()
        try:
            server_start_epoch = parse(status.get('server_start', None)).timestamp()
            server_uptime = current_epoch - server_start_epoch
            plugin.perfdata('uptime', server_uptime, 's')
        except:
            logger.error("Unable to parse server uptime from server_start {}".format(status.get('server_start', None)))

        # Perfdata on numbers and dates for each section
        for parent_key, parent_value in status.items():
            if isinstance(parent_value, dict):
                for child_key, child_value in parent_value.items():
                    if isinstance(child_value, int) or (isinstance(child_value, str) and child_value.isnumeric()):
                        plugin.perfdata("{}_{}".format(parent_key, child_key), child_value)
                    else:
                        try:
                            plugin.perfdata("{}_{}".format(parent_key, child_key), parse(child_value).timestamp(),'s')
                        except:
                            pass
        plugin.exit()
            


# Init args
args = get_args()

# Init logging
util.init_logging(debug=args.debug, enableScreenDebug=args.enable_screen_debug, logFile='/var/log/icinga2/check_crabstick.log', logRotate=args.log_rotate, logRetention=args.log_retention)
logger.info("Processing Crabstick check with args [{}]".format(args))

# Init plugin
plugin = util.MonitoringPlugin(logger, args.mode)

# run and exit
crabstick = Crabstick(args.server, args)
logger.debug("Running check for {}".format(args.mode))
eval('crabstick.{}()'.format(args.mode))
plugin.exit()