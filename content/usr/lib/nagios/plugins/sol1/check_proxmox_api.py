#!/usr/bin/python3



from sol1_monitoring_plugins_lib import MonitoringPlugin, initLogging, initLoggingArgparse
from datetime import datetime, timedelta
from loguru import logger
from proxmoxer import ProxmoxAPI

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

class InitArgs:
    import argparse
    parser = argparse.ArgumentParser(description="Proxmox API Monitoring Checks")

    # Proxmox API settings
    parser.add_argument('--server', type=str, help='Proxmox API server ip or fqdn, eg: proxmox.example.com', required=True)
    parser.add_argument('--port', type=str, help='Proxmox API server port', default='8007')
    parser.add_argument('--api-user', type=str, help='Proxmox API id', required=True)
    parser.add_argument('--api-token-name', type=str, help='Proxmox API token name', required=True)
    parser.add_argument('--api-token-value', type=str, help='Proxmox API token value', required=True)
    
    # Debug and Logging settings
    initLoggingArgparse(parser)

    # Connection type
    subparser = parser.add_subparsers(title='Mode', dest='mode', help='Help for mode', required=True)

    # Modes
    # Status
    parserBackup = subparser.add_parser("backups", help="Return the status backups.")
    parserBackup.add_argument('--since', help="", required=False)

    @classmethod
    def parse_args(cls, _args = None):
        # Parse the arguments
        args = cls.parser.parse_args(_args)
        
        # Add any post parsing validation here
        return args


class ProxmoxPVE:    
    # import urllib3
    # urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    def __init__(self, server, port, api_user, api_token_name, api_token_value, _args):
        self._args = _args
        self.init_proxmox(server, port, api_user, api_token_name, api_token_value)
        # self.pbs_headers = {
        #     "Authorization": f"PVEAPIToken={api_user}!{api_token_name}={api_token_value}"
        # }
    proxmox_api = None
    def init_proxmox(self, server, port, api_user, api_token_name, api_token_value, verify_ssl=False):
        self.proxmox_api = ProxmoxAPI(server, port=port, user=api_user, token_name=api_token_name, token_value=api_token_value,  verify_ssl=verify_ssl, service='PVE')

    _cluster_tasks = None
    @property
    def cluster_tasks(self):
        if self._cluster_tasks is None:
            try:
                self._cluster_tasks = self.proxmox_api.cluster.tasks.get()
                logger.debug(self._cluster_tasks)
            except Exception as e:
                logger.error(f"failed to get data for tasks: {e}")
        return self._cluster_tasks

    _cluster_vms = None
    @property
    def cluster_vms(self):
        if self._cluster_vms is None:
            try:
                self._cluster_vms = self.proxmox_api.cluster.resources.get('?type=vm')
                logger.debug(self._cluster_vms)
            except Exception as e:
                logger.error(f"failed to get data for vm's: {e}")
        return self._cluster_vms
    
    _cluster_backup = None
    @property
    def cluster_backups(self):
        if self._cluster_backup is None:
            try:
                self._cluster_backup = self.proxmox_api.cluster.backup.get()
                logger.debug(self._cluster_backup)
            except Exception as e:
                logger.error(f"failed to get data for vm's: {e}")
        return self._cluster_backup

    # This url has not backed up info, not using it but perhaps useful later
    # https://scramjet.hq.sol1.net:8006/api2/json/cluster/backup-info/not-backed-up

    def backups(self):
        # Make datasets for backups without vm's, vm's without backups and the combined data of a backup and vm so we can process it 
        backups = {
            'vms_with_task': [],
            'vms_with_backupjob': [],
            'vms_missing_task': [],
            'vms_missing_backupjob': [],
            'task_missing_vm': [],
            'vm_task_result': {},
            'vm_in_backup': []
        }

        # Get vm id lists for vm's, tasks and backup jobs
        vm_ids = {str(vm['vmid']) for vm in self.cluster_vms}
        
        backup_ids = set()
        backup_ids_excluded = set()
        for backup in self.cluster_backups:
            if str(backup.get('enabled', None)) == '1':
                if 'vmid' in backup:
                    backup_ids.update(str(backup['vmid']).split(','))
                if 'exclude' in backup:
                    backup_ids_excluded.update(str(backup['exclude']).split(','))
        task_ids = {str(task['id']) for task in self.cluster_tasks if task.get('type', None) == 'vzdump' and datetime.fromtimestamp(task.get('starttime', None)) > (datetime.now() - timedelta(hours=24)) and str(task['id']).isnumeric()}
        excluded_vm_ids = {str(vm['vmid']) for vm in self.cluster_vms if 'backupexcluded' in str(vm.get('tags', []))}

        # ID's that aren't explictly excluded from exclude backups (stuff that is backed up by jobs that exclude other id's)
        caught_ids = vm_ids - backup_ids_excluded
        # ID's that aren't in a backup, task or excluded vm id's
        # TODO: Check the task id here
        vms_missing_task_or_backupjob = vm_ids - backup_ids - task_ids - excluded_vm_ids - caught_ids
        # TODO: WTF MATE, why do we have a task id minusing a vmid
        tasks_missing_vm = task_ids - excluded_vm_ids - vm_ids
        backups_missing_vm = backup_ids - excluded_vm_ids - vm_ids
        backups_with_excluded_vm = excluded_vm_ids.intersection(backup_ids)

        logger.debug(f"vm_ids: {vm_ids}")
        logger.debug(f"backup_ids: {backup_ids}")
        logger.debug(f"task_ids: {task_ids}")
        logger.debug(f"excluded_vm_ids: {excluded_vm_ids}")
        logger.debug(f"caught_ids: {caught_ids}")
        logger.debug(f"vms_missing_task_or_backupjob: {vms_missing_task_or_backupjob}")
        logger.debug(f"tasks_missing_vm: {tasks_missing_vm}")
        logger.debug(f"backups_missing_vm: {backups_missing_vm}")
        logger.debug(f"backups_with_excluded_vm: {backups_with_excluded_vm}")
        

        task_by_status = {}
        for task in self.cluster_tasks:
            if task['id'] in task_ids:
                backup_status = task.get('status', 'status unknown')
                if backup_status not in task_by_status:
                    task_by_status[backup_status] = {'id': [], 'upid': []}
                task_by_status[backup_status]['id'].append(task.get('id', ''))   
                task_by_status[backup_status]['upid'].append(task.get('upid', ''))   

        # Backup tasks by status
        for status in task_by_status.keys():
            state = plugin.STATE_OK
            if status != 'OK':
                state = plugin.STATE_CRITICAL
            plugin.message = "\n"    
            plugin.setMessage(f"VM Tasks with status '{status}' - ", state, True)
            if sorted(set(task_by_status[status]['id'])):
                plugin.message = f" id's {','.join(sorted(set(task_by_status[status]['id'])))}"
            if sorted(set(task_by_status[status]['upid'])):
                plugin.message = f" upid's {','.join(sorted(set(task_by_status[status]['upid'])))}"
            plugin.message = "\n"

            plugin.setPerformanceData(label=f"state_{status.lower()}", value=len(task_by_status[status]))            

        ## Now add detail
        # VM id's that can't be matched with a backup job or task
        plugin.setPerformanceData(label=f"vms_missing_backup", value=len(list(vms_missing_task_or_backupjob))) 
        if len(list(vms_missing_task_or_backupjob)) > 0:
            plugin.failure_summary = "VM's don't have a recent backup task or aren't part of a backup job"
            plugin.message = "\n"
            plugin.setMessage(f"VM's not backed up \n", plugin.STATE_CRITICAL, True)
            for vm in self.cluster_vms:
                if str(vm['vmid']) in list(vms_missing_task_or_backupjob):
                    plugin.message = f"  vm: {vm['name']} ({vm['vmid']}) on {dict(vm).get('node', '')} in state {dict(vm).get('status', '')}\n"

        # Tasks with vm id's that don't exist
        plugin.setPerformanceData(label=f"tasks_missing_vm", value=len(list(tasks_missing_vm))) 
        if len(list(tasks_missing_vm)) > 0:
            plugin.failure_summary = "Tasks exist that aren't linked to a VM"
            plugin.message = "\n"
            plugin.setMessage(f"Task with no VM or for VM that doesn't exist \n", plugin.STATE_WARNING, True)
            for task in self.cluster_tasks:
                if str(task['id']) in list(tasks_missing_vm):
                    plugin.message = f"  task: {task['id']} ({task['upid']}) on {task['node']} in status {task['status']} ran {datetime.fromtimestamp(task['starttime'])} - {datetime.fromtimestamp(task['endtime'])}\n"

        # VM id's that aren't exluded from a exclusion list (it is assumed that exclusion is used as a catch all for forgotten backup jobs and that the jobs should be moved to a proper back job)
        plugin.setPerformanceData(label=f"not_excluded_vm", value=len(list(caught_ids))) 
        if len(list(caught_ids)) > 0:
            plugin.failure_summary = "VM's aren't excluded from the catch all backup"
            plugin.message = "\n"
            plugin.setMessage(f"VM's not excluded from catch all backup \n", plugin.STATE_WARNING, True)
            for vm in self.cluster_vms:
                if str(vm['vmid']) in list(caught_ids):
                    plugin.message = f"  vm: {vm['name']} ({vm['vmid']}) on {dict(vm).get('node', '')} in state {dict(vm).get('status', '')}\n"


        # Backup jobs with vm id's that don't exist
        plugin.setPerformanceData(label=f"backups_missing_vm", value=len(list(backups_missing_vm))) 
        if len(list(backups_missing_vm)) > 0:
            plugin.failure_summary = "Backups exist that aren't linked to a VM"
            plugin.message = "\n"
            plugin.setMessage(f"Backup Jobs configured with VM's that don't exist \n", plugin.STATE_WARNING, True)
            for backup in self.cluster_backups:
                if str(backup.get('enabled', None)) == '1':
                    intersection = set(backup.get('vmid', '').split(',')) & backups_missing_vm
                    if intersection:
                        plugin.message = f"  backup: {backup['comment']} ({backup['id']}) of {backup['type']} stored on {backup['storage']} configured with vm's {list(intersection)} which don't exist\n"     

        # VM's in back jobs with the backupexcluded tag
        plugin.setPerformanceData(label=f"backups_with_excluded_vm", value=len(list(backups_with_excluded_vm))) 
        if len(list(backups_with_excluded_vm)) > 0:
            plugin.failure_summary = "Backups exist for VM's with the tag 'backupexcluded'"
            plugin.message = "\n"    
            plugin.setMessage(f"Backups with excluded VM's - ", plugin.STATE_WARNING, True)
            for backup in sorted(backups_with_excluded_vm):
                plugin.message = f"{next((vm['name'] for vm in self.cluster_vms if str(vm['vmid']) == backup), '')} ({backup}), "
            plugin.message = "\n"

        # VM's in backup jobs
        for backup_job in self.cluster_backups:
            logger.debug(backup_job)
            plugin.message = "\n"    
            plugin.message = f"Info: VM's in enabled scheduled backup job '{backup_job.get('comment', '')}' ({backup_job.get('id', 'missing comment and id')}) - "
            if 'vmid' in backup_job:
                for backup in sorted(str(backup_job['vmid']).split(',')):
                    plugin.message = f"{next((vm['name'] for vm in self.cluster_vms if str(vm['vmid']) == backup), '')} ({backup}), "
            if 'exclude' in backup_job:
                for backup in vm_ids - set(sorted(str(backup_job['exclude']).split(','))):
                    plugin.message = f"{next((vm['name'] for vm in self.cluster_vms if str(vm['vmid']) == backup), '')} ({backup}), "
            plugin.message = "\n"

            plugin.setPerformanceData(label=f"job_{backup_job.get('id', 'missing_id')}", value=len(str(backup_job.get('vmid', '')).split(',')))     

        # VM's with backupexcluded tag
        if len(list(excluded_vm_ids)) > 0:
            plugin.message = "\n"    
            plugin.message = f"Info: Excluded VM's - "
            for backup in sorted(excluded_vm_ids):
                plugin.message = f"{next((vm['name'] for vm in self.cluster_vms if str(vm['vmid']) == backup), '')} ({backup}), "
            plugin.message = "\n"

        plugin.success_summary = "All vm's are backed up"
        plugin.setOk()



# class ProxmoxPBS:    
#     import urllib3
#     urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
#     def __init__(self, server, port, api_id, api_token, _args):
#         self.server = server
#         self.port = port
#         self.api_id = api_id
#         self.api_token = api_token
#         self._args = _args
#         #    <API token: <username>@pbs!<api id>:<api secret>>'
#         self.headers = {
#             "Authorization": f"PBSAPIToken={api_id}:{api_token}"
#         }

#     def _get_backups(self):
#         since = datetime.combine(datetime.today(), time.min)
#         if self._args.since:
#            pass
#         logger.debug(since)
#         url = f"https://{self.server}:{self.port}/api2/json/nodes/localhost/tasks"
#         logger.debug(url)
#         logger.debug(self.headers)
#         response = requests.get(url, verify=False, timeout=5, headers=self.headers)
#         if response.status_code == 401:
#             logger.error(f"Authentication failed: {response.text}")
#             plugin.setMessage(f"Authentication failed for https://{self.server}:{self.port}\n", plugin.STATE_CRITICAL, True)
#             plugin.exit()
#         if response.status_code != 200:
#             logger.error(f"invalid response code {response.status_code}: {response.text}")
#             plugin.setMessage(f"Failed to access or process https://{self.server}:{self.port}\n", plugin.STATE_CRITICAL, True)
#             plugin.exit()
#         if response.status_code == 200:
#             try:
#                 jsondata = response.json() # Check the JSON Response Content documentation below
#             except Exception as e:
#                 logger.error(f"Unable to parse response from {url}: {e}")
#                 logger.debug(response.text)
#                 plugin.setMessage(f"Authentication failed for https://{self.server}:{self.port}\n", plugin.STATE_CRITICAL, True)
#                 plugin.exit()
#         logger.debug(jsondata)
#         return jsondata

#     def backups(self):
#         taskoutput = {
#             'by_status': {}
#         }
#         processfailure=0
#         backups = self._get_backups()
#         for backup in backups['data']:
#             status = backup.get('status', 'unknown')
#             if status == '' or status == None:
#                status == 'unknown'

#             if ':' in status:
#                 status = status.split(':')[0] 
            
#             if status not in taskoutput['by_status']:
#                 taskoutput['by_status'][status] = []

#             taskoutput['by_status'][status].append({
#                 'worker_id': backup['worker_id'],
#                 'worker_type': backup['worker_type'],
#                 'user': backup['user'],
#                 'type': 'error',
#                 'status': backup['status'],
#                 'starttime': str(datetime.fromtimestamp(backup['starttime'])),
#                 'endtime': str(datetime.fromtimestamp(backup['endtime'])),
#             })

#         logger.debug(json.dumps(taskoutput, indent=4))

#         # TODO: all the output now
#         for status in taskoutput['by_status'].keys():
#             status_count = len(taskoutput['by_status'][status])
#             plugin.message = f"Status {status.lower()} count: {status_count}\n"
#             if str(status_count).isnumeric():
#                 plugin.setPerformanceData(label=status,value=status_count)
            

if __name__ == "__main__":
    # Init args
    args = InitArgs.parse_args()

    # Init logging
    initLogging(debug=args.debug, 
                enable_screen_debug=args.enable_screen_debug, 
                enable_log_file=not args.disable_log_file, 
                log_level=args.log_level, 
                log_file='/var/log/icinga2/check_proxmox.log', 
                log_rotate=args.log_rotate, 
                log_retention=args.log_retention
                )

    logger.info("Processing Proxmox check with args [{}]".format(args))

    # Init plugin
    plugin = MonitoringPlugin()

    # _requests_cache = initRequestsCache(cache_file=f'/tmp/proxmox_{args.server}.cache',expire_after=10)
    # if _requests_cache[0]:
    #     logger.debug(_requests_cache[1])
    # else:
    #     logger.error(_requests_cache[1])

    # Run and exit
    proxmox = ProxmoxPVE(args.server, args.port, args.api_user, args.api_token_name, args.api_token_value, args)
    logger.debug("Running check for {}".format(args.mode))
    eval('proxmox.{}()'.format(args.mode))
    plugin.exit()
  





