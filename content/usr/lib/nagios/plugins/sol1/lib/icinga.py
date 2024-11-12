
import requests
from requests.auth import HTTPBasicAuth
from types import SimpleNamespace

from loguru import logger
from lib.util import logError
from json import loads

import urllib3
# because certificates cannot be verified
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
class Icinga:
    def __init__(self, server, user, password):
        logger.info(f"init Icinga object")
        self.server = server.rstrip('/')
        self.__user = user
        self.__password = password
        self.__headers = {
            "Accept": "application/json",
            "Content-Type": "application/json"
        }
        logger.debug(f"Icinga object properties: server={self.server}, user={self.__user}")

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
                logger.error(f"Icinga request not GET or POST, this shouldn't happen.")
            logger.debug(f"Icinga {reqtype} response {response}")
        except Exception as e:
            logger.error(f"Icinga request error for {url}: {e}")
            try:
                logger.error(f"Response found {response}")
            except:
                response = SimpleNamespace(text=f"{e}", status_code=599)


        # If we don't get a good error message then add a error but still return the result
        if response.status_code not in [200,201,202,300,301]:
            logger.error(f"Icinga request bad return code for {url}. Response code: {response.status_code}\n Response text: \n{response.text}")

        try:
            if decode_json:
                result = loads(response.text)
            else:
                result = response.text
        except Exception as e:
            result = response.text
            logger.error(f"Icinga request parse error for {url}: {e}")
        logger.info(f"Icinga {reqtype} response: {response}")
        return result

    def _urlParams(self, base_url, **kwargs):
        url = f"{self.server}{base_url}"
        for k,v in kwargs.items():
            url = f"{url}&{k}={v}" 
        return url

    def getCheckResults(self, obj_type, filter):
        """_summary_

        Args:
            type (string): object type to get ['services', 'hosts']
            filter (_type_): filter required to get services or hosts

        Returns:
            array: array of check result objects
        """        
        checks = []
        url = url = f"{self.server}/v1/objects/{obj_type}"
        payload = {}
        if filter is not None:
            payload["filter"] = filter
        self.__headers['X-HTTP-Method-Override'] = "GET"
        logger.debug(f"getCheckResults payload: {payload}, headers: {self.__headers}")
        result = self.post(url, payload, True)
        del self.__headers['X-HTTP-Method-Override']
        if result is not None and "results" in result:
            checks = result["results"]
        return checks

    def processServiceCheckResult(self, host, service, status, message, perfdata = None, command_endpoint = None):
        filter = f'host.name=="{host}" && service.name=="{service}"'
        return self.processCheckResult("Service", filter, status, message, perfdata, command_endpoint)

    def processHostCheckResult(self, host, status, message, perfdata = None, command_endpoint = None):
        filter = f'host.name=="{host}"'
        return self.processCheckResult("Host", filter, status, message, perfdata, command_endpoint)

    def processCheckResult(self, type, filter, status, message, perfdata = None, command_endpoint = None):
        # object ApiUser "username" {
        #         password = "password"
        #         permissions = [ "actions/process-check-result" ]
        # }

        # 
        #{
        #    "type": "Service",                                                                                 # Required
        #    "filter": "host.name==\"icinga2-master1.localdomain\" && service.name==\"passive-ping\"",          # Required
        #    "exit_status": 2,                                                                                  # Required
        #    "plugin_output": "PING CRITICAL - Packet loss = 100%",                                             # Required
        #    "performance_data": ["pl=100%;80;100;0"],                                                          # Optional
        #    "check_source": "example.localdomain",                                                             # Optional. Usually the name of the command_endpoint
        #}        
        url = f"{self.server}/v1/actions/process-check-result"
        ## Required fields
        payload = {
            "type": type,
            "filter": filter,
            "exit_status": status,                                               
            "plugin_output": message                                             
        }
        ## Optional fields
        # Performance data
        if perfdata is not None:
            payload['performance_data'] = perfdata
        # The name of the command endpoint if required
        if command_endpoint is not None:
            payload['check_source'] = command_endpoint
        logger.info(f"Icinga check result to url: {url} with filter {filter}")
        logger.debug(f"Icinga check result to url: {url} with payload {payload}")

        # Send the check results
        result = self.post(url, payload, True)

        # Process response and return the result 
        # Additional logging result details
        check_results = []
        errors = []
        if "results" in result:
            for check in result['results']:
                if 'status' in check:
                    if check['status'].startswith("Successfully processed check result for object"):
                        check_results.append(check['status'])
                    else:
                        errors.append(check['status'])
                else:
                    errors.append[check]
        else:
            errors.append(result)
        if check_results:
            logger.info(f"Icinga recheck success for {type} with filter {filter}: {', '.join(check_results)}")
        if errors:
            logger.error(f"Icinga recheck errors for {type} with filter {filter}: {', '.join(errors)}")
        return result



    def rescheduleCheck(self, host):
        # object ApiUser "username" {
        #         password = "password"
        #         permissions = [ "actions/reschedule-check" ]
        # }
        url = f"{self.server}/v1/actions/reschedule-check"
        logger.info(f"Icinga recheck request for {host}")

        # bit of sanitation of host string
        invalid_chars = ['=', '*', '?', ";", "<", ">", "|"]
        if any(substring in host for substring in invalid_chars):
            logger.error(f"host string ({host}) contains invalid characters {', '.join(invalid_chars)}")
        payload = {
            "type": "Service",
            "filter": f'host.name=="{host}"',   # use exact match syntax to ensure we only do a single host
            "force": True
        }
        result = self.post(url, payload, True)
        rechecks = []
        errors = []
        if "results" in result:
            for check in result['results']:
                if 'status' in check:
                    if check['status'].startswith("Successfully rescheduled check for object"):
                        rechecks.append(check['status'])
                    else:
                        errors.append(check['status'])
                else:
                    errors.append[check]
        else:
            errors.append(result)
        if rechecks:
            logger.info(f"Icinga recheck success for {host}: {', '.join(rechecks)}")
        if errors:
            logger.error(f"Icinga recheck errors for {host}: {', '.join(errors)}")
        return result
        

