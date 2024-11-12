#!/usr/bin/env python3

import requests
import argparse

from lib.util import MonitoringPlugin, init_logging
from loguru import logger

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


NODEPOOL_URI = '/storagepool/nodepools/'
QUOTAS_URI = '/quota/quotas/'
SESSION_URI = '/session/1/session'

def get_args(argvals=None):
    parser = argparse.ArgumentParser(description='Check Isilon Quota')
    parser.add_argument('--server', type=str, help='Isilon server', required=True)
    parser.add_argument('--port', type=int, help='Isilon Server port', default=8080)
    parser.add_argument('--proto', type=str, help='Isilon Server protocol', default='https')
    parser.add_argument('--proxy', type=str, help='Proxy server', default=None)
    parser.add_argument('--username', type=str, help='Server username', default=None)
    parser.add_argument('--password', type=str, help='Server password', default=None)
    parser.add_argument('--apiversion', type=str, help='API Version', default=None)
    parser.add_argument('--nodepoolID', type=str, help='Nodepool ID', default=None)
    parser.add_argument('--quotaID', type=str, help='SmartQuota ID', default=None)
    
    
    parser.add_argument('--debug', action="store_true")
    parser.add_argument('--enable-screen-debug', action="store_true")
    parser.add_argument('--log-rotate', type=str, default='1 day')
    parser.add_argument('--log-retention', type=str, default='3 days')

    # Command type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    parserQuota = subparser.add_parser("Nodepool", help="Check Nodepool usage")
    parserQuota.add_argument('--warning', help="Greater than value for warning", default=None)
    parserQuota.add_argument('--critical', help="Greater than value for critical", default=None)

    parserQuota = subparser.add_parser("Quota", help="Check Quota Usage")
    parserQuota.add_argument('--warning', help="Greater than value for warning", default=None)
    parserQuota.add_argument('--critical', help="Greater than value for critical", default=None)

    args = parser.parse_args(argvals)
    return args


class Isilon:
    def __init__(self, server, port = None, proto = 'https', proxy = None, username = None, password = None, apiversion = None, nodepoolID = None, quotaID = None, warning = None, critical = None):
        self.server = server
        self.port = port
        self.proto = proto
        self._proxy = proxy
        self._username = username
        self._password = password
        self.apiversion = apiversion
        self._nodepoolID = nodepoolID
        self._quotaID = quotaID
        self.warning = warning
        self.critical = critical
        self.session = requests.Session()
        self._sessionid = None
        self._csrf = None
        self._headers = {"X-CSRF-Token": f"{self._csrf}", "Referer": f"{self.proto}://{self.server}:{self.port}"}
        self._get_auth_token()

        
    @property
    def proxy(self):
        if self._proxy is not None:
            return { "http": self._proxy, "https": self._proxy }
        else: 
            return self._proxy

    @property
    def base_url(self):
        port = ''
        if self.port is not None:
            port = f":{self.port}"
        return f"{self.proto}://{self.server}{port}/platform/{self.apiversion}"
    
    def _get(self, url):
        if not self._sessionid:
            logger.warning("Session hasn't been established. Please connect first with basic authorisation.")
            return None

        response = self.session.get(url, headers=self._headers, verify=False)
        logger.debug(f"URL used in get function is: {url}")
        logger.debug(f"Headers being sent are: {self._headers}")

        if response.status_code in [200, 201]:
            data = response.json()
            logger.debug("Data retrieved successfully:")
            logger.debug(data)
            return data
        else:
            logger.info("Failed to retrieve data.")
            return None

    def _post(self, url, headers, payload):
        try:
            response = self.session.post(url, headers=headers, json=payload, verify=False)
            logger.debug(f"response ({response.status_code}): {response.text}")
            return response
        except Exception as e:
            logger.error(f"Error posting to {url}: {e}")
            return None

    def _get_auth_token(self):
        auth_endpoint = f"{self.proto}://{self.server}:{self.port}{SESSION_URI}"
        logger.debug(auth_endpoint)
        headers = {"Content-Type": "application/json"}
        payload = {"username": self._username, "password": self._password, "services": ["platform"]}
        response = self._post(auth_endpoint, headers=headers, payload=payload)
        logger.debug(response.cookies)
        if response is None:
            logger.error(f"Request failed to get a response")
        elif response.status_code in [200, 201]:
            self._sessionid = response.cookies.get('isisessid')
            self._csrf = response.cookies.get('isicsrf')
            logger.debug(f"SessionID is: {self._sessionid}")
            logger.debug(f"CSRF Token is: {self._csrf}")
        else:
            logger.error(f"Request failed with status code {response.status_code}")

    # Url's
    def _getNodepool(self):
        url = f"{self.base_url}{NODEPOOL_URI}{self._nodepoolID}"
        return self._get(url)
    
    def _getQuota(self):
        url = f"{self.base_url}{QUOTAS_URI}{self._quotaID}"
        return self._get(url)
    
    def Nodepool(self):
        self._headers = {"X-CSRF-Token": f"{self._csrf}", "Referer": f"{self.proto}://{self.server}:{self.port}"}
        nodepool_result = self._getNodepool()
        if nodepool_result is not None:
            # It worked
            _np_name = (nodepool_result['nodepools'][0]['name'])
            _np_pct_used = round(float((nodepool_result['nodepools'][0]['usage']['pct_used'])),2)
            print(_np_pct_used)
            _np_warning = 85.00
            _np_critical = 90.00
            
            if _np_pct_used < _np_warning:
                plugin.setMessage(f"Nodepool usage for {_np_name} is {_np_pct_used}%\n", plugin.STATE_OK, True)
            if _np_pct_used >= _np_warning:
                plugin.setMessage(f"Nodepool usage for {_np_name} is {_np_pct_used}%\n", plugin.STATE_WARNING, True)
            if _np_pct_used >= _np_critical:
                plugin.setMessage(f"Nodepool usage for {_np_name} is {_np_pct_used}%\n", plugin.STATE_WARNING, True)

            plugin.setPerfdata(label='nodepool_usage', value=_np_pct_used)

        else:
            # It didn't work
            plugin.setMessage("Failed to get any information from the Isilon\n", plugin.STATE_CRITICAL, True)


    def Quota(self):
        self._headers = {"X-CSRF-Token": f"{self._csrf}", "Referer": f"{self.proto}://{self.server}:{self.port}"}
        quota_result = self._getQuota()
        if quota_result is not None:
            # It worked
            _path = (quota_result['quotas'][0]['path'])
            _usage = int(quota_result['quotas'][0]['usage']['fslogical'])
            _advisory_exceeded = (quota_result['quotas'][0]['thresholds']['advisory_exceeded'])
            _soft_exceeded = (quota_result['quotas'][0]['thresholds']['soft_exceeded'])
            _hard_exceeded = (quota_result['quotas'][0]['thresholds']['hard_exceeded'])
            tebibyte = 1099511627776
            plugin.message = f"Info: Current usage for {_path} is {round(float(_usage / tebibyte), 2)}TB\n"
            
            if quota_result['quotas'][0]['thresholds']['advisory'] != None:
                _advisory = int(quota_result['quotas'][0]['thresholds']['advisory'])
                logger.debug(f"Advisory quota is: {_advisory} bytes")
            else:
                _advisory = "no value"
                logger.debug(f"Advisory quota is: {_advisory}")
            
            if quota_result['quotas'][0]['thresholds']['soft'] != None:
                _soft = int(quota_result['quotas'][0]['thresholds']['soft'])
                logger.debug(f"Soft quota is: {_soft} bytes")
            else:
                _soft = "no value"
                logger.debug(f"Soft quota is: {_soft}")

            if quota_result['quotas'][0]['thresholds']['hard'] != None:
                _hard = int(quota_result['quotas'][0]['thresholds']['hard'])
                logger.debug(f"Hard quota is: {_hard} bytes")
            else:
                _hard = "no value"
                logger.debug(f"Hard quota is: {_hard}")
            
            if _advisory and _soft and _hard != "no value":
                if _advisory != "no value":
                        if _advisory_exceeded != True:
                            plugin.setMessage(f"Advisory quota for {_path} is {int(_advisory / tebibyte)}TB\n", plugin.STATE_OK, True)
                        else:
                            plugin.setMessage(f"Advisory quota for {_path} has exceeded {int(_advisory / tebibyte)}TB\n", plugin.STATE_WARNING, True)
                if _soft != "no value":
                    if _soft_exceeded != True:
                        plugin.setMessage(f"Soft quota for {_path} is {int(_soft / tebibyte)}TB\n", plugin.STATE_OK, True)
                    else:
                        plugin.setMessage(f"Soft quota for {_path} has exceeded {int(_soft / tebibyte)}TB\n", plugin.STATE_WARNING, True)
                if _hard != "no value":
                    if _hard_exceeded != True:
                        plugin.setMessage(f"Hard quota for {_path} is {int(_hard / tebibyte)}TB\n", plugin.STATE_OK, True)
                    else:
                        plugin.setMessage(f"Hard quota for {_path} has exceeded {int(_hard / tebibyte)}TB\n", plugin.STATE_CRITICAL, True)
            else:
                plugin.setMessage(f"No quotas for {_path} have been set\n", plugin.STATE_OK, True)
            
            plugin.setPerfdata(label='quota_usage', value=round(float(_usage / tebibyte), 2))
        
        else:
            # It didn't work
            plugin.setMessage("Failed to get any information from the Isilon\n", plugin.STATE_CRITICAL, True)


args = get_args()
logfile = "/var/log/icinga2/check_isilon_info.log"
init_logging(debug=args.debug, enableScreenDebug=args.enable_screen_debug, logFile=logfile, logRotate=args.log_rotate, logRetention=args.log_retention)
logger.info(f"Isilon check called with: {args}")

# MonitoringPlugin initalizes with STATE_UNKNOWN
plugin = MonitoringPlugin(logger, f"Isilon {args.mode}")

isilon = Isilon(server=args.server, port=args.port, proto=args.proto, proxy=args.proxy, username=args.username, password=args.password, apiversion=args.apiversion, nodepoolID=args.nodepoolID, quotaID=args.quotaID, warning=args.warning, critical=args.critical)
logger.debug(isilon)
logger.debug("Running check for {}".format(args.mode))
try:
    eval(f'isilon.{args.mode}()')
except Exception as e:
    plugin.setMessage("Unable to evaluate arguments\n", plugin.STATE_CRITICAL, True)
    logger.error(f"Unable to evaluate arguments with error {e}")

plugin.exit()