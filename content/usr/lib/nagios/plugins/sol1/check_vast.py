#!/usr/bin/env python3

import argparse
import pickle
import os
import requests
import re
import urllib.parse
import humanize

from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse
from datetime import datetime
from loguru import logger
from urllib3.exceptions import InsecureRequestWarning
from pathlib import Path

# Suppress only the single warning from urllib3 needed.
requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

# http debugging
#import logging
#import http.client as http_client
#http_client.HTTPConnection.debuglevel = 1
#logging.basicConfig()
#logging.getLogger().setLevel(logging.DEBUG)
#requests_log = logging.getLogger("requests.packages.urllib3")
#requests_log.setLevel(logging.DEBUG)
#requests_log.propagate = True

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Vast API Monitoring Checks")

    # Vast API settings
    parser.add_argument('-s', '--server', type=str, help='Vast API server url, eg: https://vast.example.com', required=True)
    parser.add_argument('-u', '--username', type=str, help='Vast API username', required=True)
    parser.add_argument('-p', '--password', type=str, help='Vast API password', required=True)
    parser.add_argument('--timeout', type=int, help='Http request timeout', default=15)
    
    initLoggingArgparse(parser, log_file='/var/log/icinga2/check_vast.log')

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # Clusters
    parserClusters = subparser.add_parser("clusters", help="Return the status of the clusters.")

    # Alarms
    parserAlarms = subparser.add_parser("alarms", help="Return the alarms.")
    parserAlarms.add_argument('--quiet-ids', type=str, help="Ignore alarms of these comma-separated type ids")

    # Capacity
    parserCapacity = subparser.add_parser("capacity", help="List the capacity usage.")
    parserCapacity.add_argument('--percentage', type=float, help="How small a percentage to report, without a depth it will go deeper until it finds directories under the percent")
    parserCapacity.add_argument('--depth', type=int, help="How deep in directories to report, will limit how deep the search is, starts at root no matter what the path is, default is unlimited")
    parserCapacity.add_argument('--path', type=str, help="Where to start the search", default = '/')

    args = parser.parse_args(argvals)

    return args


class Vast:
    def __init__(self, baseurl, username, password, _args):
        self.baseurl = str(baseurl).rstrip('/')
        self.__username = username
        self.__password = password
        self.__token = None
        self.__session = requests.Session()     # Holds the session including cookies
        self.__access_token = "/tmp/vast.token"
        self.__headers = {'Accept': 'application/json', 'Content-Type': 'application/json'}
        self.timeout = _args.timeout
        self._args = _args

        self.__getAccessToken()                        # We login on init to get the cookie for all other requests


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
        return self.__request('post', url, payload, parseresult)

    def get(self, url, parseresult = True):
        """ requests get

        Args:
            url ([type]): url to get from
            parseresult (bool, optional): should the result from the request be parsed as json. Defaults to True.

        Returns:
            [type]: result of request
        """
        return self.__request('get', url, None, parseresult)

    def __request(self, reqtype, url, payload = None, parseresult: bool = True):
        try:
            logger.debug("Request to {url} using {type}\n".format(url=url, type=reqtype.upper()))
            if reqtype == 'get':
                response = self.__session.get(url=url, headers=self.__headers, verify=False, timeout=self.timeout)
            elif reqtype == 'post':
                response = self.__session.post(url=url, headers=self.__headers, json=payload, verify=False, timeout=self.timeout)
                logger.debug(f"Result from {reqtype} {url} using headers {self.__headers} is {response}\n")
            else:
                plugin.message = "This shouldn't happen, code gone bad\n"
                plugin.exit(plugin.STATE_CRITICAL)

        except Exception as e:
            plugin.message = "Could not access api for {}, request failed.\n".format(url)
            logger.error("Request error for {url}: {error}".format(url=url, error=e))
            plugin.exit(plugin.STATE_CRITICAL)

        # if the request fails as unauthorised then retry once after a non cached login
        if response.status_code in [401,403]:
            self.__getAccessToken(True)
            logger.debug("Auth error ({code}), retrying request to {url}".format(url=url,code=response.status_code))
            result = self.__request(reqtype, url, payload, parseresult)
            logger.debug("Auth error ({code}), retried request to {url}".format(url=url,code=response.status_code))
            return result

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

            #logger.debug(f"Return from {type} {url}: {result}")
            return result

    def __setAuthorization(self, access_result, fresh_auth: bool = False):
        """Adds the token to class var self.__token.
           Will try again on cached requests if the token is too old
           but will fail if there is no valid token after a fresh request

        Args:
            access_result ([type]): Result of the request to get a Access Token
            fresh_auth (bool, optional): If the access result is from a fresh request or cached. Defaults to False.
        """        
        try:
            self.__token = access_result["access"]
            self.__headers['Authorization'] = f"Bearer {self.__token}"
            logger.debug(f"Authorization header set to '{self.__headers['Authorization']}")
        except Exception as e:
            plugin.message = f"Unable to get access token from access_results"
            logger.error(f"Parse error for access token {access_result}: {e}")
            plugin.exit(plugin.STATE_CRITICAL)

    # Vast auth is via token, to get the token we use the api login path
    def __getAccessToken(self, force: bool = False):
        """ Get login for session with Vast server
            will attempt to use a cached to disk session

        Args:
            force (bool, optional): Skip cache and force new login to VOS server. Defaults to False.
        """
        # Permissions check
        if os.path.isfile(self.__access_token):
            if not os.access(self.__access_token, os.W_OK):
                plugin.message = f"Permissions error, unable to write to session cookie file ({self.__access_token})\n"
                plugin.exit(plugin.STATE_CRITICAL)

        # Get the access token from cache
        if not force and os.path.isfile(self.__access_token):
            with open(self.__access_token, 'rb') as f:
                self.__setAuthorization(pickle.load(f))
                logger.debug(f"Login using loaded cached access token [{self.__access_token}]")
        # Get the access token with a request
        else:
            url = f"{self.baseurl}/api/token/"
            payload = {
                "username": self.__username,
                "password": self.__password,
            }
            logger.debug(f"Login details: url {url}, username {self.__username})")

            # don't try and cache the login itself
            logger.info(f"Getting access token using api call to {url}")
            request_time = datetime.now().timestamp()
            try:
                results = self.post(url, payload, True)
            except Exception as e:
                logger.error(f"Token request failed with: {e}")
                plugin.message(f"Auth error accessing Vast: token\nSee {os.getpid()} in logs for more details\n")
                plugin.exit()
            if isinstance(results, dict) and 'access' in results:
                results["request_time"] = request_time
                self.__setAuthorization(results, True)
                with open(self.__access_token, 'wb') as f:
                    pickle.dump(results, f)
            else:
                logger.error(f"Token request returned result is not a dict or missing access token: {results}")
                plugin.message(f"Auth error accessing Vast: token\nSee {os.getpid()} in logs for more details\n")
                plugin.exit()

    def _apiUrl(self, path, param = {}):
        url = f"{self.baseurl}/api/{path}/" 
        if param:
            urlparam = urllib.parse.urlencode(param)
            url = f"{url}?{urlparam}"
        return url
    
    def _api_get(self, path, param={}):
        url = self._apiUrl(path,param)
        result = self.get(url=url, parseresult=True)
        logger.trace(result)
        return result

    def clusters(self):
        result = self._api_get('clusters')
        if result:
            for cluster in result:
                num = cluster['id']
                desc = f"Cluster {num} '{cluster['name']}'"
                for status in ['ssd_raid_state','nvram_raid_state','memory_raid_state']:
                    plugin.setMessage(f"{desc}: {status} is '{cluster[status]}'\n", plugin.STATE_OK if cluster[status] == 'HEALTHY' else plugin.STATE_WARNING, True)
                for status in ['drr','physical_drr_percent', 'logical_drr_percent', 'physical_space_in_use_tb', 'logical_space_in_use_tb']:
                    plugin.message = f"INFO: {desc}: {status} is '{cluster[status]}'\n"
                for status in ['upgrade_phase']:
                    plugin.message = f"INFO: {desc}: {status} is '{cluster[status]}'\n"
        else:
            plugin.setMessage(f"No clusters in API\n", plugin.STATE_CRITICAL, True);

    def alarms(self):
        result = self._api_get('alarms')
        alarms = []
        if isinstance(result,list):
            quiet = []
            if self._args.quiet_ids:
                quiet = self._args.quiet_ids.split(',')
            for alarm in result:
                num = alarm['id']
                msg = alarm['alarm_message']
                sev = alarm['severity']
                state = plugin.STATE_WARNING
                if sev == 'CRITICAL':
                    state = plugin.STATE_CRITICAL
                if alarm['event_definition']:
                    match = re.search(r'/api/eventdefinitions/(\d+)/',alarm['event_definition'])
                else:
                    match = False
                event_def = 0
                if match:
                    event_def = match.group(1)
                desc = f"Alarm [{event_def}] {num} [{sev}] '{msg}'"
                if event_def in quiet:
                    state = plugin.STATE_OK
                    desc = f"[IGNORED] {desc}"
                alarms.append({"state": state,"desc": desc})
            if alarms:
                for alarm in sorted(alarms, key=lambda n: n['state'], reverse=True):
                    plugin.setMessage(f"{alarm['desc']}\n", alarm['state'], True)
            else:
                plugin.setMessage(f"API returned no Alarms\n", plugin.STATE_OK, True);
        else:
            plugin.setMessage(f"No alarms in API\n", plugin.STATE_CRITICAL, True);

    def capacity(self):
        result = self._capacity_search(self._args.path)
        if result:
            plugin.setOk() # we found the directory
            keys = result['keys']
            totals = result['root_data']
            if self._args.percentage:
                threshold = int(totals[0]*self._args.percentage/100)
            else:
                threshold = None
            output = {}
            cache = {}
            done = {'/'}
            directories = result['details']
            # go through each directory
            while len(directories):
                directory = directories.pop(0)
                path = directory[0]
                depth = len(Path(path).parents)
                if self._args.depth and depth > self._args.depth:
                    continue
                details = directory[1]
                cache[path] = details
                physical = details['data'][0]
                if not threshold or physical >= threshold:
                    logger.debug(f"Path {path}: {physical} >= {threshold}")
                    percent = physical/totals[0]*100
                    drr = details['data'][2]/physical
                    output[path] = [f"{path}: [{'%.2f' % drr}:1] {'%s' % float('%.2g' % percent)}% {humanize.naturalsize(physical)}",physical]
                    # exclude directories we already have children of
                    if path in done:
                        logger.debug(f"Path {path} already done") # {' + '.join(done)}")
                    elif self._args.depth and depth == self._args.depth:
                        logger.debug(f"Path {path} don't need to go deeper")
                    else:
                        parents = set(map(lambda n: n[1]['parent'],directories))
                        if path in parents:
                            logger.debug(f"Path {path} already in parents") #: {' + '.join(parents)}")
                        else:
                            directories.extend(self._capacity_search(path=path)['details'])
                            done.add(path)
                else:
                    logger.debug(f"Path {path}: {physical} < {threshold}")

            # sort output descending
            path_order = sorted(output.keys(), key=lambda p: output[p][1], reverse=True)
            for path in path_order:
                plugin.message = f"INFO: {output[path][0]}\n"
                plugin.setPerformanceData(f"{path}",output[path][1],'b')
        else:
            plugin.setMessage(f"No capacity in API\n", plugin.STATE_CRITICAL, True);

    def _capacity_search(self, path='/'):
        return self._api_get('capacity',{"path": path})



# Init args
args = get_args()

# Init logging
initLogging(debug=args.debug, 
             enable_screen_debug=args.enable_screen_debug, 
             enable_log_file=not args.disable_log_file, 
             log_level=args.log_level, 
             log_file=args.log_file, 
             log_rotate=args.log_rotate, 
             log_retention=args.log_retention
             )
logger.info("Processing Vast check with args [{}]".format(args))

# Init plugin
plugin = MonitoringPlugin(args.mode)

# Run and exit
vast = Vast(args.server, args.username, args.password, args)
logger.debug("Running check for {}".format(args.mode))
eval('vast.{}()'.format(args.mode))
plugin.exit()
