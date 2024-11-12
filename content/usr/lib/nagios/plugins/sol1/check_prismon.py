#!/usr/bin/env python3

import argparse
import os
import pickle
import requests
import requests_cache


from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse
from lib.util import initRequestsCache
from datetime import datetime
from loguru import logger

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description="Primon API Monnitoring Checks")

    # Prismon API settings
    parser.add_argument('-s', '--server', type=str, help='Prismon API server url, eg: http://prismon.example.com', required=True)
    parser.add_argument('-u', '--username', type=str, help='Prismon API username', required=True)
    parser.add_argument('-p', '--password', type=str, help='Prismon API password', required=True)
    parser.add_argument('--timeout', type=int, help='Http request timeout', default=15)
    
    initLoggingArgparse(parser, log_file='/var/log/icinga2/check_prismon.log')

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # Status
    parserSource = subparser.add_parser("source", help="Return the status of a service.")
    parserSource.add_argument('--id', help="ID of the source to parse", required=True)

    args = parser.parse_args(argvals)

    return args


class Prismon:
    def __init__(self, baseurl, username, password, _args):
        self.baseurl = str(baseurl).rstrip('/')
        self.__username = username
        self.__password = password
        self.__token = None
        self.__session = requests.Session()     # Holds the session including cookies
        self.__access_token = "/tmp/prismon.token"
        self.__headers = {'Accept': 'application/json', 'Content-Type': 'application/json'}
        self.timeout = _args.timeout

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
        # because Prismon wants the token as a paramater in get request
        s = "?"
        if "?" in url:
            s = "&"
        return self.__request('get', "{url}{seperator}username={user}&token={token}".format(url=url, seperator=s, user=self.__username, token=self.__token), None, parseresult)

    def __request(self, reqtype, url, payload = None, parseresult: bool = True, retry: bool = False):
        try:
            logger.debug("Request to {url} using {type}\n".format(url=url, type=reqtype.upper()))
            if reqtype == 'get':
                if retry:
                    with requests_cache.disabled():           
                        response = self.__session.get(url=url, headers=self.__headers, verify=False, timeout=self.timeout)
                else:
                    response = self.__session.get(url=url, headers=self.__headers, verify=False, timeout=self.timeout)
                plugin.message = "Result from cache: {cache}\n".format(cache=response.from_cache)
            elif reqtype == 'post':
                response = self.__session.post(url=url, headers=self.__headers, data=payload, verify=False, timeout=self.timeout)
                logger.debug("Result from {url} using headers {headers} is {result}\n".format(url=url, headers=self.__headers, result=response))
            else:
                plugin.message = "This shouldn't happen, code gone bad\n"
                plugin.exit(plugin.STATE_CRITICAL)

            self.__from_cache = response.from_cache
            logger.info("Result from {url} cache status {cache}\n".format(url=url, cache=response.from_cache))

        except Exception as e:
            plugin.message = "Could not access api for {}, request failed.\n".format(url)
            logger.error("Request error for {url}: {error}".format(url=url, error=e))
            plugin.exit(plugin.STATE_CRITICAL)

        # if the request fails as unauthorised the retry once after a non cached login
        if response.status_code in [401] and not retry:
            self.__getAccessToken(True)
            self.__request(reqtype, url, payload, parseresult, True)
            logger.debug("Auth error, retrying request to {url}".format(url=url))

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

    def __setAuthorization(self, access_result, fresh_auth: bool = False):
        """Adds the token to class var self.__token.
           Will try again on cached requests if the token is too old
           but will fail if there is no valid token after a fresh request

        Args:
            access_result ([type]): Result of the request to get a Access Token
            fresh_auth (bool, optional): If the access result is from a fresh request or cached. Defaults to False.
        """        
        try:
            if (access_result["request_time"] + access_result["expires_in"]) > datetime.now().timestamp():
                # Set the access token if it hasn't expired
                self.__token = access_result["access_token"]
            else:
                if fresh_auth:
                    plugin.message = f"Fresh request has an expired access token [{access_result}]\n"
                    logger.error(f"Fresh request has a expired access token {access_result}")
                    plugin.exit(plugin.STATE_CRITICAL)

                else:
                    # Try for a fresh access token if the cached version has expired
                    self.__getAccessToken(True)

        except Exception as e:
            plugin.message = f"Unable to get access token from access_resultn"
            logger.error(f"Parse error for access token {access_result}: {e}")
            plugin.exit(plugin.STATE_CRITICAL)

    # VOS auth is via cookie, to get the cookie we use the api login path
    def __getAccessToken(self, force: bool = False):
        """ Get login for session with VOS server
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
            url = f"{self.baseurl}/auth/realms/prismon/protocol/openid-connect/token"
            payload = {
                "client_id": "webui",
                "username": self.__username,
                "password": self.__password,
                "grant_type": "password",
                "scope": "offline_access"
            }
            logger.debug(f"Login details: url {url}, username {self.__username})")
            self.__headers = { 
                'Content-Type': 'application/x-www-form-urlencoded', 
            }
            # don't try and cache the login itself
            with requests_cache.disabled():   
                logger.info(f"Getting access token using api call to {url}")
                request_time = datetime.now().timestamp()
                try:
                    results = self.post(url, payload, True)
                except Exception as e:
                    logger.error(f"Token request failed with: {e}")
                    plugin.message(f"Auth error accessing Prismon2: token\nSee {os.getpid()} in logs for more details\n")
                    plugin.exit()
                if isinstance(results, dict) and 'access_token' in results:
                    results["request_time"] = request_time
                    if not str(results.get("expires_in", None)).isnumeric():
                        results["expires_in"] = 300        
                    self.__headers = {'Accept': 'application/json', 'Content-Type': 'application/json'}
                    self.__setAuthorization(results, True)
                    with open(self.__access_token, 'wb') as f:
                        pickle.dump(results, f)
                else:
                    logger.error(f"Token request returned result is not a dict or missing access token: {results}")
                    plugin.message(f"Auth error accessing Prismon2: token\nSee {os.getpid()} in logs for more details\n")
                    plugin.exit()

    def _apiUrl(self, type, recursive = False):
        url = f"{self.baseurl}/-/"
        if recursive:
            url = f"{url}r/"
        url = f"{url}{type}/" 
        return url
    
    def _getSource(self, id = None):
        url = self._apiUrl('spu.sources')
        if id is not None:
            url = f"{url}{id}/"
        result = self.get(url=url, parseresult=True)
        logger.trace(result)
        return result
            

    def source(self):
        result = self._getSource(args.id)
        plugin.message = f"Info: Description - {result.get('DESCRIPTION', 'missing')}"

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
logger.info("Processing Prismon check with args [{}]".format(args))

# Init plugin
plugin = MonitoringPlugin(args.mode)

_requests_cache = initRequestsCache(cache_file=f'/tmp/prismon_{args.server}.cache',expire_after=10)
if _requests_cache[0]:
    logger.debug(_requests_cache[1])
else:
    logger.error(_requests_cache[1])

# Run and exit
prismon = Prismon(args.server, args.username, args.password, args)
logger.debug("Running check for {}".format(args.mode))
eval('prismon.{}()'.format(args.mode))
plugin.exit()