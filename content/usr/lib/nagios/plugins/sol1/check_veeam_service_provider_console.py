#!/usr/bin/env python3

#Imports
import argparse
import humanize
import json
import re
import requests
import traceback

from loguru import logger
from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse
from lib.util import initRequestsCache
from lib.icinga import Icinga
from datetime import datetime, timedelta, timezone
from dateutil.parser import parse

from requests.packages import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Use the Veeam Service Provider Console api and return metrics")

    # Global Settings
    parser.add_argument('-u', '--url', type=str, help='Veeam Service Provider Console server url including port, eg: http://example.com:1280', required=True)
    parser.add_argument('-t', '--token', type=str, help='Veeam Service Provider Console token', required=True)

    parser.add_argument('--cacheage', type=int, help='Maximum age for cached API data (in seconds)', required=False, default=120)

    initLoggingArgparse(parser)

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    parserBackupServersJobs = subparser.add_parser("BackupServersJobs", help="Backup Server Jobs for Virtual Machines")
    parserBackupServersJobs.add_argument('--organization', type=str, help='Organization name for backup job', required=True)
    parserBackupServersJobs.add_argument('--name', type=str, help='Name of backup job', default=None)
    parserBackupServersJobs.add_argument('--age', type=int, help='Max age of backup job in hours', default=24)
    
    parserOrganisationMonitoring = subparser.add_parser("OrganisationMonitoring", help="For each organisation check Icinga for monitoring")
    parserOrganisationMonitoring.add_argument('--icinga-url', type=str, help='Icinga server url including port, eg: http://example.com:5665', required=True)
    parserOrganisationMonitoring.add_argument('--icinga-user', type=str, help='Icinga user', required=True)
    parserOrganisationMonitoring.add_argument('--icinga-password', type=str, help='Icinga password', required=True)
    parserOrganisationMonitoring.add_argument('--service-filter', type=str, help='Service filter used in find services and extract the Org names from the service name', required=True)
    parserOrganisationMonitoring.add_argument('--service-org-var', type=str, help='Service var that contains the service name', default='veeamspc_organization')
    parserOrganisationMonitoring.add_argument('--exclude', type=str, action='append', help="Organization names that don't need a backup check")
    
    parserBackup365 = subparser.add_parser("Backup365Jobs", help="Backup Microsoft 365 Jobs")
    parserBackup365.add_argument('--organization', type=str, help='Organization name for backup job', required=True)
    parserBackup365.add_argument('--name', type=str, help='Name of backup job', default=None)
    parserBackup365.add_argument('--age', type=int, help='Max age of backup job in hours', default=24)

    return parser.parse_args(argvals)


class VeeamServiceProviderConsole():
    def  __init__(self, url: str, token: str, args):
        self.url = url.rstrip('/')
        self._token = token
        self._args = args
        self._backup_server_jobs = None
        self._backup_365_jobs = None
        self._organizations = None
        self.__headers = {
            'Accept': 'application/json', 
            'Authorization': token
        }
    
    # API Calls
    def post(self, url, payload, parseresult = True):
        """ requests post

        Args:
            url (string): url to post to
            payload (string): payload for post
            parseresult (bool, optional): should the result from the request be parsed as json. Defaults to True.

        Returns:
            [type]: result of request
        """
        return self.__request('POST', url, payload, parseresult)

    def get(self, url, parseresult = True):
        """ requests get

        Args:
            url ([type]): url to get from
            parseresult (bool, optional): should the result from the request be parsed as json. Defaults to True.

        Returns:
            [type]: result of request
        """
        return self.__request('GET', url, None, parseresult)

    def __request(self, reqtype, url, payload = None, parseresult: bool = True):
        try:
            logger.debug("Request to {url} using {type}\n".format(url=url, type=reqtype))
            if reqtype == 'GET':
                response = requests.get(url=url, headers=self.__headers, verify=False)
                logger.debug("{reqtype} result from {url} using headers {headers} is {result}\n".format(url=url, headers=self.__headers, result=response, reqtype=reqtype))
            elif reqtype == 'POST':
                response = requests.post(url=url, headers=self.__headers, json=payload, verify=False)
                logger.debug("{reqtype} of {payload} result from {url} using headers {headers} is {result}\n".format(url=url, headers=self.__headers, result=response, reqtype=reqtype, payload=payload))
            else:
                plugin.message = "This shouldn't happen, code gone bad\n"
                plugin.exit(plugin.STATE_CRITICAL)

        except Exception as e:
            plugin.message = "Could not access api for {reqtype} {url}, request failed.\n".format(url=url, reqtype=reqtype)
            logger.error("Request error for {url}: {error}".format(url=url, error=e))
            plugin.exit(plugin.STATE_CRITICAL)

        else:
            if response.status_code not in [200,201,300,301]:
                plugin.message = "Could not access api for {}.\n Response code: {}\n Response text: \n{}".format(url, response.status_code, response.text)
                plugin.exit(plugin.STATE_CRITICAL)

            try:
                if parseresult:
                    result = response.json()
                else:
                    result = response.text
            except Exception as e:
                plugin.message = "Unable to parse json data from request {}\n Response text: \n{}".format(url, response.text)
                logger.error("Parse error for {url}: {error}".format(url=url, error=e))
                plugin.exit(plugin.STATE_CRITICAL)

            return result    

    @property        
    def backup_servers_jobs(self):
        if self._backup_server_jobs is None:
            url = f"{self.url}/api/v3/infrastructure/backupServers/jobs"
            self._backup_server_jobs = self._getPaginated(url)
            logger.debug(self._backup_server_jobs)
        return self._backup_server_jobs

    @property
    def backup_365_jobs(self):
        if self._backup_365_jobs is None:
            url = f"{self.url}/api/v3/infrastructure/vb365Servers/organizations/jobs"
            self._backup_365_jobs = self._getPaginated(url)
            logger.debug(self._backup_365_jobs)
        return self._backup_365_jobs

    @property
    def organizations(self):
        if self._organizations is None:
            url = f"{self.url}/api/v3/organizations"
            self._organizations = self._getPaginated(url)
            logger.debug(self._organizations)
        return self._organizations

    def _getPaginated(self, url):
        offset = 0
        limit = 100
        count = 1
        result = {
            "meta": {
                "pagingInfo": {
                    "total": 999,
                    "count": 0,
                    "offset": 0
                }
            },
            "data": []
        }
        while count < 50:
            try:
                if result['meta']['pagingInfo']['total'] > result['meta']['pagingInfo']['count']: 
                    _result = self.get(url=f"{url}?limit={limit}&offset={offset}")
                    offset += limit
                    result['meta']['pagingInfo'] = _result['meta']['pagingInfo']
                    result['data'] = result['data'] + _result['data']
                else:
                    break                    
            except Exception as e:
                logger.error(f"Unable to get paginated data with error {e}\n{traceback.format_exc()}")
                logger.debug(result)
                try:
                    logger.debug(_result)
                except:
                    pass
                plugin.setMessage(f"Error getting paginated data {e}", plugin.STATE_CRITICAL, True)
                plugin.exit()
        return result

    @staticmethod
    def toUTC(dt):
        if not isinstance(dt, datetime):
            dt = parse(dt)
        if dt.tzinfo is None:  # if it's naive, assume it's in UTC
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)      

    def Backup365Jobs(self):
        backup_jobs = []
        for backup in self.backup_365_jobs.get('data', []):
            # if name is missing do all backups or just do the named backup
            if self._args.name is None or backup.get('name', None) == self._args.name:
                # we don't need to link the order because we already have the name, though vspcOrganizationUid should match organization['instanceUid']
                if backup.get('vspcOrganizationName', None) == self._args.organization:
                    logger.debug(f"adding {backup.get('name', None)} from {backup.get('vspcOrganizationName', None)}")
                    backup_jobs.append(backup)

        for job in backup_jobs:
            logger.debug(job)

            name = job.get('name', '')    
            organization = job.get('vspcOrganizationName', '')
            status = job.get('lastStatus', 'missing')
            status_details = job.get('lastStatusDetails', '')
            is_enabled = job.get('isEnabled', False)
            
            now = datetime.now(timezone.utc)
            last_run = job.get('lastRun', None)
            if last_run:
                last_run = self.toUTC(last_run)
            next_run = job.get('nextRun', None)
            if next_run:
                next_run = self.toUTC(next_run)

            error_log = {}
            for error in job.get('lastErrorLogRecords', []):
                if 'logType' in error and str(error['logType']).lower() not in error_log:
                    error_log[str(error['logType']).lower()] = []
                error_log[str(error['logType']).lower()].append(str(error.get('message', '')))    

            # count applies to all messages
            if 'error' in error_log:
                plugin.setMessage(f"365 Backup {name} for {organization} has error messages\n", plugin.STATE_CRITICAL, True)
            else:
                plugin.message = f"365 Backup {name} for {organization}\n"

            # overall status
            if status.lower() == 'error':
                plugin.setMessage(f"Overall status is {status} with details {status_details} and is currently {'Enabled' if is_enabled else 'Disabled'}\n", plugin.STATE_CRITICAL, True)
            else:
                plugin.message = f"Info: Overall status is {status} with details {status_details} and is currently {'Enabled' if is_enabled else 'Disabled'}\n"

            # make sure there aren't any time problems
            if last_run is None:
                plugin.setMessage(f"Last backup run start time is missing\n", plugin.STATE_CRITICAL, True)
            else:
                plugin.message = f"Info: Last backup run start time is {humanize.naturaltime(now - last_run)} ({last_run.astimezone().strftime('%d/%m/%Y %H:%M:%S %Z %z')})\n"
                        
            # We finish writing out the messages here
            error_count = 0
            # do the error messages first
            if job.get('lastErrorLogRecords', []):
                plugin.message = "\nLog messages found (max 10 shown).\n"
            for message in list(set(error_log.get('error', []))):
                if error_count < 10:
                    plugin.message = f"error: {message}\n" 
                else:
                    break
                error_count += 1
            # then the warning messages
            for message in list(set(error_log.get('warning', []))):
                if error_count < 10:
                    plugin.message = f"warning: {message}\n" 
                else:
                    break
                error_count += 1
            # now any remaining messages
            for error in error_log.keys():
                plugin.setPerformanceData(label=f'{error}_messages', value=len(error_log[error]))
                if error not in ['error', 'warning']:
                    for message in error_log[error]:
                        if error_count < 10:
                            plugin.message = f"{error}: {message}\n" 
                        else:
                            break
                        error_count += 1
                
            if error_count < 10:
                pass
            else:
                plugin.message = f"\nthere are {len(job.get('lastErrorLogRecords', [])) - 10} more messages not shown.\n Refer to the console to see all messages\n"

            plugin.setPerformanceData(label=f'total_messages', value=len(job.get('lastErrorLogRecords', [])))
        plugin.setOk()

            
    def BackupServersJobs(self):
        backup_jobs = []
        # Loop through backups to find matching names
        for backup in self.backup_servers_jobs.get('data', []):
            # if name is missing do all backups or just do the named backup
            if self._args.name is None or backup.get('name', None) == self._args.name:
                logger.trace(backup.get('name', None))
                if backup.get('organizationUid', None) is not None:
                    # Loop through orgs to find matching orgs
                    for organization in self.organizations.get('data', []):
                        if backup['organizationUid'] == organization.get('instanceUid', None):
                            logger.trace(f"{organization.get('name', None)} == {self._args.organization}")
                            if organization.get('name', None) == self._args.organization:
                                logger.debug(f"adding {backup.get('name', None)} from {organization.get('name', None)}")
                                # Set the org name on the backup and add it to list of matching jobs
                                backup['organizationName'] = organization.get('name', '')
                                backup_jobs.append(backup)

        for job in backup_jobs:
            logger.debug(job)

            # vars used for all the jobs
            name = job.get('name', '')
            # tests
            last_endtime = job.get('lastEndTime', None) 
            now = datetime.now(timezone.utc)
            if last_endtime is not None:
                last_endtime = self.toUTC(last_endtime)
            status = job.get('status', 'missing')
            is_enabled = job.get('isEnabled', None)
            # metrics 
            last_duration = job.get('lastDuration', '')
            averge_duration = job.get('avgDuration', '')
            transferred_data = job.get('transferredData', '')

            # We only output failed backups, so not success or old endtime
            if is_enabled is not True:
                plugin.setMessage(f"Backup {name} for {job.get('organizationName', '')} has isEnabled value {is_enabled}\n", plugin.STATE_WARNING, True)
            elif status == 'Success' and last_endtime is not None and last_endtime > now - timedelta(hours=self._args.age):
                plugin.setMessage(f"Backup {name} for {job.get('organizationName', '')}\n", plugin.STATE_OK, True)
            else:
                plugin.message = f"\nInfo: Job name - {name}\n"
                plugin.message = f"Info: Organization - {job.get('organizationName', '')}\n"

                if status in ['Success']:
                    state = plugin.STATE_OK
                elif status in ['Warning']:
                    state = plugin.STATE_WARNING
                else: 
                    state = plugin.STATE_CRITICAL
                plugin.setMessage(f"Status - {status}\n", state, True)

                last_run = job.get('lastRun', None) 

                # if the last run time doesn't exist that is a problem
                if last_run is None:
                    plugin.setMessage(f"Last backup run start time is missing\n", plugin.STATE_CRITICAL, True)
                else:
                    last_run = self.toUTC(last_run)
                    plugin.message = f"Info: Last backup run start time is {humanize.naturaltime(now - last_run)} ({last_run.astimezone().strftime('%d/%m/%Y %H:%M:%S %Z %z')})\n"

                # if the last run end time doesn't exist that is a problem
                if last_endtime is None:
                    plugin.setMessage(f"Last backup run end time is missing\n", plugin.STATE_CRITICAL, True)
                else:
                    # if the last run end time is too old we have a problem
                    if last_endtime < now - timedelta(hours=self._args.age):
                        plugin.setMessage(f"Last backup run end time is {humanize.naturaltime(now - last_endtime)} ({last_endtime.astimezone().strftime('%d/%m/%Y %H:%M:%S %Z %z')}) which is more than {self._args.age} hours old\n", plugin.STATE_CRITICAL, True)
                    else:
                        if last_endtime < last_run:
                            plugin.setMessage(f"Backup is currently running, last completed backup was {humanize.naturaltime(now - last_endtime)} ({last_endtime.astimezone().strftime('%d/%m/%Y %H:%M:%S %Z %z')})\n", plugin.STATE_OK, True)
                        else:
                            plugin.setMessage(f"Backup completed, backup end time is {humanize.naturaltime(now - last_endtime)} ({last_endtime.astimezone().strftime('%d/%m/%Y %H:%M:%S %Z %z')})\n", plugin.STATE_OK, True)

                plugin.message = f"Info: Bottleneck - {job.get('bottleneck', None)}\n"


                plugin.message = f"Info: Last Duration - {humanize.naturaldelta(last_duration)}\n"
                plugin.message = f"Info: Average Duration - {humanize.naturaldelta(averge_duration)}\n"
                plugin.message = f"Info: Transferred Data - {humanize.naturalsize(int(transferred_data)) if str(transferred_data).isnumeric() else transferred_data}\n"
                plugin.message = "\n"

            if str(last_duration).isnumeric():
                plugin.setPerformanceData(label=f"{re.sub('[^0-9a-zA-Z_]+', '', name).lower()}_lastDuration", value=last_duration, unit_of_measurement='s')

            if str(averge_duration).isnumeric():
                plugin.setPerformanceData(label=f"{re.sub('[^0-9a-zA-Z_]+', '', name).lower()}_avgDuration", value=averge_duration, unit_of_measurement='s')

            if str(transferred_data).isnumeric():
                plugin.setPerformanceData(label=f"{re.sub('[^0-9a-zA-Z_]+', '', name).lower()}_transferredData", value=transferred_data, unit_of_measurement='B')
        plugin.exit()
            

    def OrganisationMonitoring(self):
        icinga = Icinga(server=self._args.icinga_url, user=self._args.icinga_user, password=self._args.icinga_password)
        icinga_checks = icinga.getCheckResults('services', f'{self._args.service_filter}')
        if not icinga_checks:
            plugin.setMessage(f"No Icinga services found matching {self._args.service_filter}*", plugin.STATE_CRITICAL, True)
            plugin.exit()
        logger.debug(icinga_checks)
        icinga_check_names = []        
        try:
            for check in icinga_checks:
                # Get the icinga service name (host!service), extract out the service part then replace the prefix which should give us the org name
                icinga_check_names.append(str(check.get('attrs', {}).get('vars', {}).get(self._args.service_org_var, '')))
        except Exception as e:
            logger.error(f"Error getting list of icinga checks: {e}")
            plugin.setMessage(f"Error getting list of icinga checks: {e}\n", plugin.STATE_CRITICAL, True)
        logger.debug(icinga_check_names)

        missing_orgs = []
        found_orgs = []
        excluded_orgs = []
        if self._args.exclude:
            excluded_orgs = self._args.exclude
        for organization in self.organizations.get('data', []):
            organization_name = organization.get('name', 'missing organisation name')
            if organization_name in icinga_check_names:
                found_orgs.append(organization_name)
            else:
                if organization_name not in excluded_orgs:
                    missing_orgs.append(organization_name)

        if len(missing_orgs) > 0:
            plugin.setMessage(f"Veeam Organisations missing checks - {', '.join(missing_orgs)}\n", plugin.STATE_CRITICAL, True)
        else: 
            plugin.setMessage(f"No Veeam Organisations are missing checks\n", plugin.STATE_OK, True)
            
        plugin.message = f"Info: Veeam Organisations with checks - {', '.join(found_orgs)}\n"
        plugin.message = f"Info: Veeam Organisations excluded from checks - {', '.join(excluded_orgs)}\n"

        plugin.setPerformanceData(label='veeam_orgs', value=len(self.organizations.get('data', [])))
        plugin.setPerformanceData(label='excluded_orgs', value=len(excluded_orgs))
        plugin.setPerformanceData(label='checked_orgs', value=len(found_orgs))
        plugin.setPerformanceData(label='unchecked_orgs', value=len(missing_orgs))


if __name__ == "__main__":
    # Init args
    args = get_args()

    # Init logging
    initLogging(debug=args.debug, enable_screen_debug=args.enable_screen_debug, log_file='/var/log/icinga2/check_veeam_service_provider_console.log', log_rotate=args.log_rotate, log_retention=args.log_retention)
    logger.info("Processing Veeam Service Provider Console check with args [{}]".format(args))

    initRequestsCache(cache_file = f"/tmp/vspc{hash(args.url)}.cache", expire_after=args.cacheage)

    # Init plugin
    plugin = MonitoringPlugin(args.mode)

    # run and exit
    vspc = VeeamServiceProviderConsole(args.url, args.token, args)
    logger.debug("Running check for {}".format(args.mode))
    eval('vspc.{}()'.format(args.mode))
    plugin.exit()