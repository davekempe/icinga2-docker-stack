#!/usr/bin/env python3

import lib.jsonarg as argparse
from datetime import datetime, timedelta
import humanize
import json

from lib.icinga import Icinga
from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse

from loguru import logger


def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Use the Icinga API to get check results and return a different check result")

    # Icinga API settings
    parser.add_argument('-s', '--server', type=str, help='Icinga API server url including port, eg: https://icinga.example.com:5665', required=True)
    parser.add_argument('-u', '--username', type=str, help='Icinga API username', required=True)
    parser.add_argument('-p', '--password', type=str, help='Icinga API password', required=True)
    
    # Debug and Logging settings
    initLoggingArgparse(parser)

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # Health of the service itself
    parserStatus = subparser.add_parser("redundancy", help="Test for degraded redundancy against a group of checks. All checks green is OK, partial some checks degraded is WARNING, all check degraded is CRITICAL")
    parserStatus.add_argument('--type', type=str, default='services', const='services', nargs='?', choices=['services', 'hosts'], help='Type of checks to process')
    parserStatus.add_argument('--filter', type=str, help='Filter for checks to process', required=True)
    parserStatus.add_argument('--degraded-state', type=int, default=1, const=1, nargs='?', choices=[1, 2], help='The current state threshold at which things are considered degraded. 1 = Warning, 2 = Critical', required=False)  # plugin.STATE_WARNING

    # Best
    parserBest = subparser.add_parser("best", help="Return the best of the group of checks, ignore the others.")
    parserBest.add_argument('--type', type=str, default='services', const='services', nargs='?', choices=['services', 'hosts'], help='Type of checks to process')
    parserBest.add_argument('--filter', type=str, help='Filter for checks to process', required=True)

    # Sum
    parserSum = subparser.add_parser("sum", help="Return the sum of the group of checks, including the perfdata.")
    parserSum.add_argument('--type', type=str, default='services', const='services', nargs='?', choices=['services', 'hosts'], help='Type of checks to process')
    parserSum.add_argument('--filter', type=str, help='Filter for checks to process', required=True)
    parserSum.add_argument('--warn', type=str, help='JSON dictionary of perfdata name regex to warning threshold, setting will ignore underlying check status of warning', required=False)
    parserSum.add_argument('--crit', type=str, help='JSON dictionary of perfdata name regex to critical threshold, setting will ignore underlying check status of critical', required=False)

    # Status Metrics
    parserStatusMetrics = subparser.add_parser("statusmetrics", help="Return the Status Metrics from a group of checks, including the perfdata.")
    parserStatusMetrics.add_argument('--type', type=str, default='services', const='services', nargs='?', choices=['services', 'hosts'], help='Type of checks to process')
    parserStatusMetrics.add_argument('--buffer', type=str, help='Seconds something can be past next check time before being counted as overdue', default=60, required=False)
    parserStatusMetrics.add_argument('--filter', type=str, help='Filter for checks to process', required=True)
    parserStatusMetrics.add_argument('--return-check-state', action="store_true", help='Makes the result of this check return the worst state of filtered checks instead of processing error state (default)', default=False)
    parserStatusMetrics.add_argument('--filter-check-state', type=str, help='Make the results only return metrics for a single state, the total includes all states though. 0 = ok, 1 = warn, 2 = crit, 3 = unknown', const='', nargs='?', choices=['', '0', '1', '2', '3'], default='')

    parserOverdue = subparser.add_parser("overdue", help="Find any overdue checks.")
    parserOverdue.add_argument('--type', type=str, default='services', const='all', nargs='?', choices=['all', 'services', 'hosts'], help='Type of checks to process')
    parserOverdue.add_argument('--filter', type=str, help='Filter for checks to process', required=False, default=None)
    parserOverdue.add_argument('--buffer', type=str, help='Seconds something can be past next check time before being counted as overdue', default=60, required=False)
    parserOverdue.add_argument('--warn', type=str, help='How many overdue before we warn', default=1, required=False)
    parserOverdue.add_argument('--crit', type=str, help='How many overdue before we crit', default=2, required=False)

    parserSummary = subparser.add_parser("summary", help="Summary of Services.")
    parserSummary.add_argument('--type', type=str, default='services', const='all', nargs='?', choices=['all', 'services', 'hosts'], help='Type of checks to process')
    parserSummary.add_argument('--filter', type=str, help='Filter for checks to process', required=False, default=None)
    parserSummary.add_argument('--min', type=int, help="Minimum number of results to return", default=0)
    parserSummary.add_argument('--max', type=int, help="Maximum number of results to return", default=9999)

    args = parser.parse_args(argvals)

    return args


class IcingaChecker(Icinga):
    def __init__(self, server, user, password, _args):
        self._args = _args
        super().__init__(server, user, password)  
        logger.debug(f"Class args: {self._args}")
    
    def best(self):
        # Get checks
        checks = self.getCheckResults(self._args.type, self._args.filter)

        # Process checks
        best = False
        best_state = False
        try:
            for check in checks:
                check_attrs = check.get('attrs', {})
                check_state = check_attrs.get('last_check_result', {}).get('state', None)
                if check_state is not None:
                    check_state = int(check_state)
                    plugin.message = f"Info: matching check {check.get('name', 'Unknown Host/Service')}\n"
                    if not best or check_state < best_state:
                        best_state = check_state
                        best = check
                else:
                    logger.error(f"Error processing best checks, state is missing from {check_attrs.get('host_name', 'Unknown Host (attr)')} {check_attrs.get('name', 'Unknown Service (attr)')} - ({check.get('name', 'Unknown Host/Service (name)')})")
        except Exception as e:
            plugin.setMessage(f"Error processing redundancy check for {check.get('name', 'Unknown Host/Service')}\n", plugin.STATE_CRITICAL, True)
            logger.error(f"Error processing redundancy checks: {e}")
        if best:
            plugin.setMessage(best['attrs']['last_check_result']['output'], best['attrs']['last_check_result']['state'], True)
            for pd in best['attrs']['last_check_result']['performance_data']:
                parts = pd.split(';')
                main = parts[0].split('=')
                plugin.setPerformanceData(main[0], main[1], list(parts[1:]))
        else:
            plugin.message = f"No checks found to match filter '{self._args.filter}'"
            return


    def redundancy(self):
        # Get checks
        checks = self.getCheckResults(self._args.type, self._args.filter)

        # 0-1 results is bad
        check_count = len(checks)
        if check_count < 2:
            plugin.setMessage(f"Expected more than one check but only found {check_count}\nUnable to determine redundnacy state.\n", plugin.STATE_UNKNOWN, True, True)
            logger.warning(f"Expected more than one check but found: {checks}")
            plugin.exit()
        
        # Process checks
        is_degraded = 0
        is_ok = 0
        try:
            for check in checks:
                check_attrs = check.get('attrs', {})
                check_state = check_attrs.get('last_check_result', {}).get('state', None)
                if check_state is not None:
                    check_state = int(check_state)
                    if check_state >= self._args.degraded_state:
                        is_degraded += 1
                        plugin.setMessage(f"{check_attrs.get('host_name', 'Unknown Host')} {check_attrs.get('name', 'Unknown Service')} is degraded ({plugin.getStateLabel(check_state)})\n", plugin.STATE_CRITICAL)
                    else: 
                        is_ok += 1
                        plugin.setMessage(f"{check_attrs.get('host_name', 'Unknown Host')} {check_attrs.get('name', 'Unknown Service')} is functional ({plugin.getStateLabel(check_state)})\n", plugin.STATE_OK)
                else:
                    logger.error(f"Error processing redundancy checks, state is missing from {check_attrs.get('host_name', 'Unknown Host (attr)')} {check_attrs.get('name', 'Unknown Service (attr)')} - ({check.get('name', 'Unknown Host/Service (name)')})")
        except Exception as e:
            plugin.setMessage(f"Error processing redundancy check for {check.get('name', 'Unknown Host/Service')}\n", plugin.STATE_CRITICAL)
            logger.error(f"Error processing redundancy checks: {e}")

        # Test status for redundancy
        # all checks degraded = service failed
        plugin.message = "\n"
        logger.debug(f"check_count: {check_count}, is ok: {is_ok}, is degraded: {is_degraded}")
        if check_count == is_degraded:
            plugin.setMessage("The redundant service has failed\n", plugin.STATE_CRITICAL, True)
        # all checks ok = service fully functional
        elif check_count == is_ok:
            plugin.setMessage("The redundant service is fully functional\n", plugin.STATE_OK, True)
        # all checks accounted for with some degraded = working but degraded
        elif check_count == (is_degraded + is_ok) and is_degraded > 0 and is_ok > 0:
            plugin.setMessage("The redundant service is working in a degraded state\n", plugin.STATE_WARNING, True)
        # something when bad getting checks
        else:
            # something is ok
            if is_ok > 0:
                # nothing is known to be degraded
                if is_degraded == 0:
                    plugin.setMessage("The redundant service is working, it isn't showing any checks in a degraded state but some checks failed to process\n", plugin.STATE_WARNING, True)
                else: 
                    plugin.setMessage("The redundant service is working, some checks are showing as degraded and some checks failed to process\n", plugin.STATE_WARNING, True)
            else:
                plugin.setMessage("The redundant service has no working checks, some checks failed to process so we don't know if it degraded or completely failed\n", plugin.STATE_CRITICAL, True)
        plugin.setOk()
    

    def _getCheckMetrics(self, checks):
        # |         | TOTAL | ACK'D | ACK'D STICKY |
        # | OK      |       |       |              |
        # | WARN    |       |       |              |
        # | CRIT    |       |       |              |
        # | UNKNOWN |       |       |              |
        # | INVALID |       |       |              |
        # | TOTAL   |       |       |              |
        metrics = { 
            "ok": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "warning": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "critical": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "unknown": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "invalid": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "overdue": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            },
            "total": {
                "total": 0,
                "acknowledged_total": 0,
                "acknowledged_sticky": 0
            }
        }
        for check in checks:
            try:
                metrics['total']['total'] += 1
                check_attrs = check.get('attrs', {})
                last_check_result = check_attrs.get('last_check_result', {})
                check_state = None
                if last_check_result is not None:
                    check_state = last_check_result.get('state', None)
                check_ackd = check_attrs.get('acknowledgement', None)
                check_last = check_attrs.get('last_check', None)
                check_interval = check_attrs.get('check_interval', None)
                

                if check_state is not None and isinstance(int(check_state), int) and int(check_state) in range(0,3):
                    metrics_label = plugin.getStateLabel(int(check_state)).lower()
                else:
                    metrics_label = 'invalid'

                metrics[metrics_label]['total'] += 1
                if check_ackd is not None and isinstance(int(check_ackd), int):
                    if int(check_ackd) >= 1:
                        metrics['total']['acknowledged_total'] += 1
                        metrics[metrics_label]['acknowledged_total'] += 1
                    elif int(check_ackd) == 2:
                        metrics['total']['acknowledged_sticky'] += 1
                        metrics[metrics_label]['acknowledged_sticky'] += 1

            except Exception as e:
                metrics['invalid']['total'] += 1
                logger.warning(f"Error {e} for metrics on check\n{check}")

            try: 
                # Overdue metrics
                if check_last == '-1' or (isinstance(check_last, (int,float)) and isinstance(check_interval, (int,float)) and ((check_last + check_interval + self._args.buffer) < datetime.now().timestamp())):
                    metrics['overdue']['total'] += 1
                    if check_ackd is not None and isinstance(int(check_ackd), int):
                        if int(check_ackd) >= 1:
                            metrics['overdue']['acknowledged_total'] += 1
                        elif int(check_ackd) == 2:
                            metrics['overdue']['acknowledged_sticky'] += 1
            except Exception as e:
                logger.warning(f"Error {e} for overdue metrics on check\n{check}")
        return metrics

    def statusmetrics(self):
        # Get checks
        checks = self.getCheckResults(self._args.type, self._args.filter)
        logger.debug(checks)

        if not checks: # none match
            plugin.setMessage(f"No checks match type '{self._args.type}' and filter '{self._args.filter}'\n", plugin.STATE_CRITICAL, True)
            return

        # Get the metrics
        metrics = self._getCheckMetrics(checks)
        logger.debug(metrics)

        metric_states = ['ok', 'warning', 'critical', 'unknown']
        if self._args.filter_check_state != '':
            metric_states = [plugin.getStateLabel(int(self._args.filter_check_state)).lower()]

        try:
            for check in checks:
                check_attrs = check.get('attrs', {})
                check_state = check_attrs.get('last_check_result', {}).get('state', None)
                if check_state is not None:
                    return_check_state = self._args.return_check_state
                    if not isinstance(return_check_state, bool):
                        return_check_state = True
                    if self._args.filter_check_state == '' or int(self._args.filter_check_state) == int(check_state):
                        plugin.setMessage(f"{check.get('name', 'Unknown Host/Service')}:\n------\n{check_attrs['last_check_result']['output']}\n-----\n\n", check_state, return_check_state)

        except Exception as e:
            plugin.setMessage(f"Error processing sum check for {check.get('name', 'Unknown Host/Service')}\n", plugin.STATE_CRITICAL, True)
            logger.error(f"Error processing redundancy checks: {e}")
            # checks_invalid += 1

        plugin.message = f"Info: {metrics['total']['total']} Total checks found, {metrics['total']['acknowledged_total']} have been acknowledged, {metrics['total']['acknowledged_sticky']} are sticky\n"
        for metric in metric_states:
            plugin.message = f"Info: {metrics[metric]['total']} {metric.upper()} checks found, {metrics[metric]['acknowledged_total']} have been acknowledged, {metrics[metric]['acknowledged_sticky']} are sticky\n"
    
        plugin.message = f"Info: {metrics['overdue']['total']} Overdue checks found, {metrics['overdue']['acknowledged_total']} have been acknowledged, {metrics['overdue']['acknowledged_sticky']} are sticky\n"

        if metrics['invalid']['total'] != 0: 
            plugin.setMessage(f"Found {metrics['invalid']['total']} invalid results\n", plugin.STATE_CRITICAL, True)
        
        for metric in metrics.keys():
            plugin.setPerfdata(f"{metric}_total", metrics[metric]['total'])
            plugin.setPerfdata(f"{metric}_ackd", metrics[metric]['acknowledged_total'])
            plugin.setPerfdata(f"{metric}_ackd_sticky", metrics[metric]['acknowledged_sticky'])
        
        plugin.setOk()        

    # Sum of performance data
    def sum(self):
        # Get checks
        checks = self.getCheckResults(self._args.type, self._args.filter)
        perfdata = {}

        if not checks: # none match
            plugin.setMessage(f"No checks match type '{self._args.type}' and filter '{self._args.filter}'\n", plugin.STATE_CRITICAL, True)
            return

        # work out warning and critical thresholds
        if self._args.warn:
            warning_thresholds = json.loads(self._args.warn)
        else:
            warning_thresholds = {}
        if self._args.crit:
            critical_thresholds = json.loads(self._args.crit)
        else:
            critical_thresholds = {}

        # Process checks
        try:
            perfdata['__TOTAL__'] = 0
            for check in checks:
                check_attrs = check.get('attrs', {})
                check_state = check_attrs.get('last_check_result', {}).get('state', None)
                if self._args.warn and check_state == plugin.STATE_WARNING:
                    check_state = plugin.STATE_OK
                if self._args.crit and check_state == plugin.STATE_CRITICAL:
                    check_state = plugin.STATE_OK
                if check_state is not None:
                    plugin.setMessage(f"{check.get('name', 'Unknown Host/Service')}:\n------\n{check['attrs']['last_check_result']['output']}\n-----\n\n", check_state, True)
                    for performance_data in check['attrs']['last_check_result']['performance_data']:
                        parts = performance_data.split(';')
                        main = parts[0].split('=')
                        if perfdata.get(main[0]):
                            perfdata[main[0]] += int(main[1])
                            if main[0] != '__TOTAL__': # don't double count nested totals
                                perfdata['__TOTAL__'] += int(main[1])
                        else:
                            perfdata[main[0]] = int(main[1])

                else:
                    logger.error(f"Error processing sum checks, state is missing from {check_attrs.get('host_name', 'Unknown Host (attr)')} {check_attrs.get('name', 'Unknown Service (attr)')} - ({check.get('name', 'Unknown Host/Service (name)')})")
        except Exception as e:
            plugin.setMessage(f"Error processing sum check for {check.get('name', 'Unknown Host/Service')}\n", plugin.STATE_CRITICAL, True)
            logger.error(f"Error processing sum checks: {e}")
        if perfdata:
            for performance_data in perfdata:
                plugin.setPerformanceData(performance_data,perfdata[performance_data])
                # do we need to alert on any perfdata #TODO handle range strings not just limits
                if self._args.crit and critical_thresholds.get(performance_data,None) != None and perfdata[performance_data] >= critical_thresholds[performance_data]:
                    plugin.setMessage(f"perf data {performance_data} {perfdata[performance_data]} >= {critical_thresholds[performance_data]}\n", plugin.STATE_CRITICAL, True)
                elif self._args.warn and warning_thresholds.get(performance_data,None) != None and perfdata[performance_data] >= warning_thresholds[performance_data]:
                    plugin.setMessage(f"perf data {performance_data} {perfdata[performance_data]} >= {warning_thresholds[performance_data]}\n", plugin.STATE_WARNING, True)
                elif self._args.crit or self._args.warn:
                    plugin.setMessage(f"perf data {performance_data} {perfdata[performance_data]} < {warning_thresholds.get(performance_data,critical_thresholds.get(performance_data,'[No Threshold]'))}\n", plugin.STATE_OK, True)


    def overdue(self):
        checks = self.getCheckResults(self._args.type, self._args.filter)
        logger.debug(checks)

        if not checks: # none match
            plugin.setMessage(f"No checks match type '{self._args.type}' and filter '{self._args.filter}'\nChecks are needed to determine if any are overdue", plugin.STATE_CRITICAL, True)
            return

        # Process checks
        overdue = {
            "total": 0,
            "acknowledged_total": 0,
            "acknowledged_sticky": 0,
            "objects": []
        }
    
        try:
            for check in checks:
                # Ref: https://icinga.com/docs/icinga-2/latest/doc/09-object-types/
                check_attrs = check.get('attrs', {})
                check_ackd = check_attrs.get('acknowledgement', None)
                check_last = check_attrs.get('last_check', None)
                check_interval = check_attrs.get('check_interval', None)
                # Can't use next_check or next_update as they are constantly updated

                # Overdue metrics builder
                overdue_time = None
                if isinstance(check_last, (int,float)) and isinstance(check_interval, (int,float)):
                    overdue_time = float(check_last) + float(check_interval) + float(self._args.buffer)

                # check_last == '-1' is never been checked
                if overdue_time is None or overdue_time < datetime.now().timestamp():
                    logger.debug(f"{check.get('name')} last checked {check_last} has overdue_time [{overdue_time}] < now [{datetime.now().timestamp()}]")
                    overdue['total'] += 1
                    overdue['objects'].append({"name": check.get('name', 'Unknown Host/Service'), "last_check": check_last, "overdue_time": overdue_time})
                    if check_ackd is not None and isinstance(int(check_ackd), int):
                        if int(check_ackd) >= 1:
                            overdue['acknowledged_total'] += 1
                        elif int(check_ackd) == 2:
                            overdue['acknowledged_sticky'] += 1
        except Exception as e:
            plugin.setMessage(f"Error processing overdue check for {check.get('name', 'Unknown Host/Service')}\n", plugin.STATE_CRITICAL, True)
            logger.error(f"Error processing redundancy checks: {e}")

            logger.debug(f"check_attrs: {check_attrs}")
            logger.debug(f"check_ackd: {check_ackd}")
            logger.debug(f"check_last: {check_last}")
            logger.debug(f"check_interval: {check_interval}")
            logger.debug(f"overdue time = {overdue_time}")
            plugin.exit()
        
        logger.debug(overdue)

        # Test metrics
        if overdue['total'] == 0:
            plugin.setMessage(f"No overdue {self._args.type} found.\n", plugin.STATE_OK, True)
            plugin.setOk()
        else: 
            plugin.setMessage(f"Overdue {self._args.type} found:\n", plugin.STATE_CRITICAL, True)
            for object in sorted(overdue['objects'], key=lambda k: k['name'].lower()):
                plugin.message = f"{object['name']} is overdue {self._age_string(object['overdue_time'])}\n"

    def summary(self):
        checks = self.getCheckResults(self._args.type, self._args.filter)
        logger.debug(checks)

        found = []        
        try:
            for check in checks:
                found.append(check.get('attrs', {}).get('name', 'No name found'))

        except Exception as e:
            logger.error(f"Error in loop for {self._args.type}: {e}")

        if len(found) > self._args.min and len(found) < self._args.max:
            plugin.setMessage(f"Found {len(found)} {self._args.type} which is more than min ({self._args.min}) and less than max ({self._args.max})\n", plugin.STATE_OK, True)
        elif len(found) < self._args.min:
            plugin.setMessage(f"Found {len(found)} {self._args.type} which is less than min ({self._args.min})\n", plugin.STATE_CRITICAL, True)
        elif len(found) > self._args.max:
            plugin.setMessage(f"Found {len(found)} {self._args.type} which is more than max ({self._args.max})\n", plugin.STATE_CRITICAL, True)

        found.sort()
        plugin.message = "\n".join(found)
        plugin.setOk()


    def _age_string(self, epoch_val):
        if str(epoch_val) == "-1":
            return "never"
        try:
            return humanize.naturaltime(datetime.now().timestamp() - epoch_val)
        except:
            return epoch_val

# Init args
args = get_args()

# Init logging
initLogging(debug=args.debug, enable_screen_debug=args.enable_screen_debug, log_file='/var/log/icinga2/check_icinga_checks.log', log_rotate=args.log_rotate, log_retention=args.log_retention)
logger.info("Processing Hybrid monitoring checks check with args [{}]".format(args))

# Init plugin
plugin = MonitoringPlugin(args.mode)

# Run and exit
icinga = IcingaChecker(args.server, args.username, args.password, args)
logger.debug("Running check for {}".format(args.mode))
eval('icinga.{}()'.format(args.mode))
plugin.exit()
