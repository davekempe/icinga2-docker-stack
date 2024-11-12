#!/usr/bin/env python3

# Check backy2 is doing it's job
# - backy2 ls
#   - get total for all targets and make sure <min threshold> of recent target jobs (by time) is met
#   - ensure no targets job size shrinks
# - df -h /mnt/backups/backy2/ 
#   - get size of backups
#   - free space check
# - ls /mnt/backups/backy2/metadata/ceph-disks/<target>/ -lh
#   - ensure the latest target job metadata id exists and is greater than 0

# Built in python as it is easier to reuse data than bash



#Imports
import argparse
import os
import re
import shutil
import sys
import subprocess
from datetime import datetime

# Pretty up the message and exit
def doExit():
    global MESSAGE
    global PERFDATA
    if exitCode == STATE_UNKNOWN:
        MESSAGE = "UNKNOWN - " + MESSAGE
    elif exitCode == STATE_CRITICAL:
        MESSAGE = "CRITICAL - " + MESSAGE
    elif exitCode == STATE_WARNING:
        MESSAGE = "WARNING - " + MESSAGE
    elif exitCode == STATE_OK:
        MESSAGE = "OK - " + MESSAGE
    print("{}|{}\n".format(MESSAGE, PERFDATA))
    sys.exit(exitCode)


def missing_jobs(this_set):
    tidy = set()
    for p in args.rbdpools.split(','):
        for j in this_set:
            tidy.add(j.replace("{}/".format(p), ""))
    return unique_rbd_names.difference(tidy)

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

MESSAGE = ""
PERFDATA = ""

exitCode=STATE_UNKNOWN

def addPerfData(name, value, unit_of_measure = "", warn = "", crit = "", pmin = "", pmax = ""):
    global PERFDATA
    PERFDATA += "{name}={value}{unit};{warn};{crit};{min};{max} ".format(name=name.replace(' ', '_').lower(), value=value, unit=unit_of_measure, warn=warn, crit=crit, min=pmin, max=pmax)


parser = argparse.ArgumentParser(description='Get status from the icinga2 api')
# Thresholds
parser.add_argument('--jobsage', type=int, help='Time in seconds for jobs that count as recent', default=90000)
parser.add_argument('--jobscount', type=int, help='Maximum number of jobs (same as increment count set in scripts)', default=14)
parser.add_argument('--jobsexclude', type=str, help='rbd job names to be excluded (comma seperated)', default="")
parser.add_argument('--wjobs', type=int, help='Minimum percentage of recent jobs vs all jobs to warn on', default=90)
parser.add_argument('--cjobs', type=int, help='Minimum percentage of recent jobs vs all jobs to crit on', default=80)
parser.add_argument('--wfree', type=int, help='Minimum free space (in GB) to warn on', default=100)
parser.add_argument('--cfree', type=int, help='Minimum free space (in GB) to crit on', default=50)

parser.add_argument('--backupdir', type=str, help='Backup destination directory', required=True)
parser.add_argument('--rbdpools', type=str, help='rbd pool names (comma seperated)', required=True)

parser.add_argument('--debug', help='Debug info', action='store_true')
args = parser.parse_args()

is_ok = {
    "dir": False
}

# Check for shell tools existance
for cmd in ['backy2', 'rbd']:
    if shutil.which(cmd) is None:
        MESSAGE += "Unable to find {} command\n".format(cmd)
        exitCode = STATE_CRITICAL
        doExit()

# Get the backy2 shell output
try:
    backy2_output = subprocess.run(["backy2", "-m", "ls"], capture_output=True, text=True).stdout
except Exception as e:
    MESSAGE += "Unable to run backy2 command\n"
    exitCode = STATE_CRITICAL
    if args.debug:
        MESSAGE += "Exception:\n{}".format(e)
    doExit()

# Parse the shell output
backy2_ls = []
keys = [ 'date', 'name', 'snapshotname', 'size', 'sizebytes', 'uid', 'valid', 'protected', 'tags', 'expire' ]

try:
    for line in backy2_output.splitlines():
        if line == 'date|name|snapshot_name|size|size_bytes|uid|valid|protected|tags|expire':
            pass
        else:
            line_dict = dict(zip(keys, line.split('|')))
            try:
                # 'date': '2021-01-11 04:47:50',
                line_dict["epoch"] = int(datetime.strptime(line_dict["date"], "%Y-%m-%d %H:%M:%S").timestamp())
            except Exception as e:
                MESSAGE += "Unable to parse time on line {}\n".format(line)        
                exitCode = STATE_CRITICAL
                if args.debug:
                    MESSAGE += "Exception:\n{}".format(e)
                doExit()
            if line_dict['name'] not in args.jobsexclude:
                backy2_ls.append(line_dict)
except Exception as e:
    MESSAGE += "Unable to parse 'backy2 -m ls' output on line {}\n".format(line)
    exitCode = STATE_CRITICAL
    if args.debug:
        MESSAGE += "Exception:\n{}".format(e)
    doExit()


# get size of backups
# free space check
if os.path.isdir(args.backupdir):
    backupdir_stat = shutil.disk_usage(args.backupdir)
    backupdir_free = int(backupdir_stat.free / 1024 / 1024 / 1024)
    backupdir_used = int(backupdir_stat.used / 1024 / 1024 / 1024)
    addPerfData("disk_free", backupdir_free * 1024, "MB", args.wfree * 1024, args.cfree * 1024)
    addPerfData("disk_used", backupdir_used * 1024, "MB")
    if backupdir_free < args.cfree:
        MESSAGE += "Backup dir: free space {free}GB is less than min required {required}GB\n".format(free=backupdir_free, required=args.cfree)
        exitCode = STATE_CRITICAL
    elif backupdir_free < args.wfree:
        MESSAGE += "Backup dir: free space {free}GB is less than min required {required}GB\n".format(free=backupdir_free, required=args.wfree)
        exitCode = STATE_WARNING
    else:
        MESSAGE += "Backup dir: free space {free}GB\n".format(free=backupdir_free)
        if exitCode == STATE_UNKNOWN:
            is_ok['dir'] = True

    MESSAGE += "Backup dir: used space {}GB\n".format(backupdir_used)
else:
    MESSAGE += "Backup dir: backup directory {} doesn't exist\n".format(args.backupdir)
    exitCode = STATE_CRITICAL
    doExit()

def get_rbd_info(pool, name):
    global MESSAGE
    global exitCode
    rbd_info = {
        "name": name,
        "pool": pool,
        "order": "",
        "snapshot_count": "",
        "id": "",
        "format": "",
        "features": "",
        "op_features": "",
        "flags": "",
        "create_timestamp": "",
        "access_timestamp": "",
        "modify_timestamp": "",
        "create_epoch": None,
        "access_epoch": None,
        "modify_epoch": None
    }
    try:
        line = "(loop for line not reached)"
        result = subprocess.run(["rbd", "info", "{}/{}".format(pool, name)], capture_output=True, text=True).stdout
        for line in result.splitlines():
            if line.startswith('rbd image '):
                pass
            elif line.startswith('size '):
                rbd_info['size'] = re.sub('^size ', '', line)
            elif line.startswith('order '):
                rbd_info['order'] = re.sub('^order ', '', line)
            elif ":" in line:
                rbd_info[line.split(":")[0].strip()] = ":".join(line.split(":")[1:]).strip()
    except Exception as e:
        MESSAGE += "Unable to parse 'rbd info {pool}/{name}' output on line {line}\n".format(pool=pool, name=name, line=line)
        exitCode = STATE_CRITICAL
        if args.debug:
            MESSAGE += "Exception:\n{}".format(e)
        doExit()


    for key in ['create', 'access', 'modify']:
        try:
            rbd_info[key + "_epoch"] = int(datetime.strptime(rbd_info[key + "_timestamp"], "%a %b %d %H:%M:%S %Y").timestamp())     #Mon Jan 18 11:25:47 2021
        except:
            pass

    return rbd_info


# list jobs that completed within the required period
recent_jobs = list(filter(lambda r: r['epoch'] >= (datetime.now().timestamp() - args.jobsage), backy2_ls))
unique_job_names = set()
for job in backy2_ls:
    if job['name'] not in args.jobsexclude:
        unique_job_names.add(job['name'])

# Get list of rbd names from backed up pools
# Assumes names are globally unique
unique_rbd_names = set()
new_rbd_names = set()
for pool in args.rbdpools.split(','):
    try:
        rbd_output = subprocess.run(["rbd", "ls", "-p", pool], capture_output=True, text=True).stdout
        for line in rbd_output.splitlines():
            if "{}/{}".format(pool, line) not in args.jobsexclude:
                if "{}/{}".format(pool, line) in unique_job_names:
                    unique_rbd_names.add(line)
                else: 
                    line_rbd_info = get_rbd_info(pool, line)
                    if line_rbd_info['create_epoch'] is not None and line_rbd_info['create_epoch'] < (datetime.now().timestamp() - args.jobsage):
                        unique_rbd_names.add(line)
                    else:
                        new_rbd_names.add(line)

    except Exception as e:
        MESSAGE += "Unable to run 'rbd ls -p {}'\n".format(pool)
        exitCode = STATE_CRITICAL
        if args.debug:
            MESSAGE += "Exception:\n{}".format(e)
        doExit()

# Do we have enough recent jobs for the rdb names
recent_job_percentage = 0
if len(recent_jobs) != 0 and len(unique_rbd_names) != 0:
    recent_job_percentage = int(len(recent_jobs) / len(unique_rbd_names) * 100)
MESSAGE = "Found {recent} recent jobs from {jobs} unique jobs, rbd has {rbd} names + {new} new names\n{existing}".format(recent=len(recent_jobs), jobs=len(unique_job_names), rbd=len(unique_rbd_names), existing=MESSAGE, new=len(new_rbd_names))
addPerfData("jobs_recent", len(recent_jobs), "", int((args.wjobs/100)*len(unique_rbd_names)), int((args.cjobs/100)*len(unique_rbd_names)))
addPerfData("jobs_unique", len(unique_job_names))
addPerfData("jobs_rbd", len(unique_rbd_names))

if recent_job_percentage < args.cjobs:
    MESSAGE += "Job count: percentage of recent jobs {recent}% is less than min required {required}%\n".format(recent=recent_job_percentage, required=args.cjobs)
    exitCode = STATE_CRITICAL
elif recent_job_percentage < args.wjobs:
    MESSAGE += "Job count: percentage of recent jobs {recent}% is less than min required {required}%\n".format(recent=recent_job_percentage, required=args.wjobs)
    exitCode = STATE_WARNING

# Process recent jobs and look for problems
metadata_bad = False
recent_job_names = set()
for job in recent_jobs:
    # list of all jobs with the same name 
    thisjobs_jobs = list(filter(lambda t: t['name'] == job['name'], recent_jobs))
    recent_job_names.add(job['name'])

    # get total for all targets and make sure <min threshold> of recent target jobs (by time) is met
    if len(thisjobs_jobs) > args.jobscount:
        MESSAGE += "Job count: {name} has {count} jobs but there shouldn't be more than {max}\n".format(name=job['name'], count=len(thisjobs_jobs), max=args.jobscount)
        exitCode = STATE_CRITICAL

    # ensure no targets job size shrinks
    for tjob in thisjobs_jobs:
        if tjob['sizebytes'] > job['sizebytes']:
            MESSAGE += "Job size: Current job {uid} is smaller than previous jobs {olduid}\n".format(uid=job['uid'], olduid=tjob['uid'])
            exitCode = STATE_CRITICAL

    # ensure the latest target job metadata id exists and is greater than 0
    try:
        job_metadata_file = args.backupdir + "/metadata/" + job['name'] + "/" + job['uid']
        if os.path.isfile(job_metadata_file):
            if int(os.stat(job_metadata_file).st_size) == 0:
                MESSAGE += "Job metadata: file {} exists but is empty\n".format(job_metadata_file)     
                exitCode = STATE_CRITICAL
                metadata_bad = True
        else:
            MESSAGE += "Job metadata warning: unable to find file {}\n".format(job_metadata_file)
            # exitCode = STATE_WARNING    # This isn't a error state as the metadata file is a backup of the db metadata and they could be missing, sometimes. Useful info to have though.
            metadata_bad = True
    except Exception as e:
        MESSAGE += "Job metadata: error checking metadata\n"
        exitCode = STATE_CRITICAL
        if args.debug:
            MESSAGE += "Exception:\n{}".format(e)
        doExit()


# Output if required
if not metadata_bad:
    MESSAGE += "Job metadata: no problems found\n"

if recent_job_percentage < 100:
    MESSAGE += "Missing from recent jobs: {}\n".format(','.join(sorted(missing_jobs(recent_job_names))))
if len(unique_job_names) == 0 or len(unique_rbd_names) == 0 or int(len(unique_job_names) / len(unique_rbd_names) * 100) < 100:
    MESSAGE += "Missing from unique jobs: {}\n".format(','.join(sorted(missing_jobs(unique_job_names))))
    
if args.debug:
    MESSAGE += "Recent job names:\n{}\n".format('\n'.join(sorted(recent_job_names)))
    MESSAGE += "Unique job names:\n{}\n".format('\n'.join(sorted(unique_job_names)))
    MESSAGE += "Unique rbd names:\n{}\n".format('\n'.join(sorted(unique_rbd_names)))
    MESSAGE += "New rbd names:\n{}\n".format('\n'.join(sorted(new_rbd_names)))

if exitCode == STATE_UNKNOWN and is_ok['dir']:
    exitCode = STATE_OK

doExit()

