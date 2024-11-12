import requests

from json import loads
from loguru import logger

class SimpleAPI:
    def __init__(self, server):
        self.__session = requests.Session()     # Holds the session including cookies
        self.server = server
        self.__headers = {'Accept': '*/*'}
    
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
        url = "{}{}".format(self.server, url)
        try:
            logger.debug("Request to {url} using {type}\n".format(url=url, type=reqtype))
            if reqtype == 'GET':
                response = self.__session.get(url=url, headers=self.__headers, verify=False)
                logger.debug("{reqtype} result from {url} using headers {headers} is {result}\n".format(url=url, headers=self.__headers, result=response, reqtype=reqtype))
            elif reqtype == 'POST':
                response = self.__session.post(url=url, headers=self.__headers, json=payload, verify=False)
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
                    result = loads(response.text)
                else:
                    result = response.text
            except Exception as e:
                plugin.message = "Unable to parse json data from request {}\n Response text: \n{}".format(url, response.text)
                logger.error("Parse error for {url}: {error}".format(url=url, error=e))
                plugin.exit(plugin.STATE_CRITICAL)

            return result    