from bs4 import BeautifulSoup
from datetime import datetime, date, timedelta
import requests
import subprocess
import dateutil.parser
import pytz
import os
import re
import textwrap
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("-v", "--verbose", help="increase output verbosity",
                    action="store_true")
parser.add_argument("-f", "--force", help="force an update of the 'static' release in tags db",
                    action="store_true")
parser.add_argument("-n", "--no_action", help="don't do a commit even if it's time",
                    action="store_true")
args = parser.parse_args()

if (not args.no_action):
    print "WARNING, LIVE RUN.  POSSIBLY WILL COMMIT."

min_builds = 3
build_ignore_list = ['ppc64', 'armv7l', 'armv6l']
svn_repo_name = "echo2"
important_projects = [['dill', 'git'], 
                      ['atl', 'git'], 
                      ['ffs', 'git'], 
                      ['evpath', 'git']]
other_projects = [['enet', 'git']]


def findnth(haystack, needle, n):
    parts= haystack.split(needle, n+1)
    if len(parts)<=n+1:
        return -1
    return len(haystack)-len(parts[-1])-len(needle)

def get_build_results(proj, age):
    day = date.today() - timedelta(age)
    day_str = day.strftime('&date=20%y-%m-%d')
    r  = requests.get('http://evpath.net/CDash/index.php?project=' + proj + day_str)
    data = r.text
    if data.startswith("This project doesn't exist.") :
        return {'build_count':-1, 'fails':-1 }
    soup = BeautifulSoup(data)
    try:
        rows = soup.find("tbody").find_all("tr")
    except AttributeError:
        return {'build_count':0, 'fails':0 }
    total = 0
    build_count = 0

    for row in rows:
        cells = row.find_all("td")
        try:
            build = cells[1].get_text()
            build = build.strip()
            if (build.find(proj) != -1) :
                build = build.replace(proj + "-", "")
            if build in build_ignore_list:
                continue
            first = cells[11].find("a")
            fails = first.get_text()
        except AttributeError:
            continue
        fails = fails.strip()
        if fails != '':
            total = total + int(fails)
        build_count = build_count + 1
        # 
        #     print(td.string)

    return {'build_count':build_count, 'fails':total }
    

def get_stable_release_date():
    r  = requests.get('https://GTkorvo.github.io/korvo_tag_db')
    stable_start = r.text[r.text.find('$korvo_tag{"stable"}'):]
    stable = stable_start[:stable_start.find(';')+1]
    item_string = stable.split('"')[3];
    items = item_string.split();
    for item in items:
        name, version = item.split(":", 1)
        if name == svn_repo_name:
            stable_version = version
    output = subprocess.check_output(['svn', 'log', '--xml', '-r', stable_version, 'http://svn.research.cc.gatech.edu/kaos'])
    svn_xml = BeautifulSoup(output)
    try:
        isodate = svn_xml.find("date").get_text()
        stable_release_date = dateutil.parser.parse(isodate)
    except AttributeError:
        output = subprocess.check_output(['svn', 'log', '--xml', '-r', str(int(stable_version)-1), 'http://svn.research.cc.gatech.edu/kaos'])
        print str(int(stable_version)-1)
        svn_xml = BeautifulSoup(output)
        try:
            isodate = svn_xml.find("date").get_text()
            stable_release_date = dateutil.parser.parse(isodate)
        except AttributeError:
            stable_release_date = pytz.utc.localize(datetime.utcnow())
    return stable_release_date

def get_last_svn_commit_date(proj):
    url = 'http://anon:anon@svn.cc.gatech.edu/kaos/'+proj+'/trunk'
    output = subprocess.check_output(['svn', 'log', '--xml', url, '--limit', '1'])
    svn_xml = BeautifulSoup(output)
    isodate = svn_xml.find("date").get_text()
    last_commit_date = dateutil.parser.parse(isodate)
    return last_commit_date

def get_last_svn_commit_revision(proj):
    url = 'http://anon:anon@svn.cc.gatech.edu/kaos/'+proj+'/trunk'
    output = subprocess.check_output(['svn', 'log', '--xml', url, '--limit', '1'])
    svn_xml = BeautifulSoup(output)
    inputtag = svn_xml.find("logentry")['revision']
    return inputtag

def get_last_git_commit_date(proj):
    url = 'http://github.com/GTkorvo/'+proj+'/commits/master'
    r  = requests.get(url)
    git_xml = BeautifulSoup(r.text)
    commit_time = git_xml.find("relative-time")['datetime']
    last_commit_time = dateutil.parser.parse(commit_time)
    return last_commit_time

def get_last_git_commit_revision(proj):
    url = 'http://github.com/GTkorvo/'+proj+'/commits/master'
    r  = requests.get(url)
    git_xml = BeautifulSoup(r.text)
    commit_body = git_xml.findAll("p", { "class" : "commit-title" })
    url = commit_body[0].find("a")['href']
    m = re.search('(.*/)([^/]+)$', url)
    return m.group(2)


def get_last_commit_date_projs(projects):
    first = 1;
    for p in projects:
        if (p[1] == 'svn'):
            this_proj_date = get_last_svn_commit_date(p[0])
        else:
            this_proj_date = get_last_git_commit_date(p[0])
        if (first == 1) :
            most_recent = this_proj_date
            first = 0
        else:
            if (most_recent < this_proj_date) :
                most_recent = this_proj_date
    print "Most recent commit is ", most_recent
    return most_recent

def check_recent_failures(projects):
    reject = 0
    for p in projects:
        for x in range(0, 3) :
            result = get_build_results(p[0].translate(None, "_"), x)
            if result['build_count'] == -1 :
                continue;
            if result['build_count'] < min_builds :
                print "Project", p[0], "has too few builds ({}) {} days ago".format(result['build_count'], x)
                reject = 1
            if result['fails'] > 0 :
                print "Project", p[0], "has too many failures {} days ago".format(x)
                reject = 1
    return reject

def generate_stable_listing(projects):
    listing = '$korvo_tag{"stable"} = "'
    newest_revision = "0"
    for p in projects:
        if (p[1] == 'svn'):
            svn_revision = get_last_svn_commit_revision(p[0])
            if (svn_revision > newest_revision):
                newest_revision = svn_revision
        
    print "Going with revision = " + newest_revision

    for p in projects:
        if (p[1] == 'svn'):
            listing = listing + " " + p[0] + ":" + newest_revision
        else:
            git_revision = get_last_git_commit_revision(p[0])
            listing = listing + " " + p[0] + ":" + git_revision

    listing = listing + '";'
    listing.replace('" ', '"')
    return listing

def rewrite_tag_db(stable_listing):
    r  = requests.get('https://GTkorvo.github.io/korvo_tag_db')
    stable_start = r.text.find('$korvo_tag{"stable"}')
    stable_end = r.text[stable_start:].find(';')+1+stable_start
    before_stable = r.text[:stable_start]
    after_stable = r.text[stable_end:]

    stable_listing = textwrap.fill(stable_listing, width=90, subsequent_indent="\t")
    file = open("korvo_tag_db", 'w')
    file.write(before_stable + stable_listing + after_stable)
    file.flush()
    file.close()
    print "Wrote new korvo_tag_db"
    svn_cmd = "/usr/bin/svn commit -m \"advance stable version\" chaos_tag_db";
    if(os.path.isdir("./.svn")) :
        if (not args.no_action):
            p = subprocess.Popen(svn_cmd, shell=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, universal_newlines=True)
        
            out, err = p.communicate() 
            print err
        else :
            print "Skipping commit because of --no_action flag"
       
today = datetime.utcnow()
today = pytz.utc.localize(today)

stable_release = get_stable_release_date()
print "stable release was at : " + str(stable_release)
if args.verbose:
    delta = (stable_release - today).total_seconds()
    delta = -delta / (60 * 60 * 24)
    print "    Time since stable release is :" + "{:4.1f}".format(delta) + " days ago"
    
if (today - stable_release < timedelta(days=7)) :
    print "Not doing a stable release because last release was too recent"
    if (not args.force):
        os._exit(0)
    else:
        print "    Skipping exit because of force"

reject = check_recent_failures(important_projects)

if (reject > 0) :
    print "Not doing a stable release because of recent failures"
    if (not args.force):
        os._exit(0)
    else:
        print "    Skipping exit because of force"
    
last_important_commit = get_last_commit_date_projs(important_projects)

if args.verbose:
    delta = (last_important_commit - today).total_seconds()
    delta = -delta / (60 * 60 * 24)
    print "Time since last important commit :" + "{:4.1f}".format(delta) + " days ago"

if (today - last_important_commit < timedelta(days=3)) :
    print "Not doing release because commits to important projects happened too recently"
    if (not args.force):
        os._exit(0)
    else:
        print "    Skipping exit because of force"

projects = important_projects
projects.extend(other_projects)

entry = generate_stable_listing(projects)

if args.verbose:
    print "Last release was", (today - get_stable_release_date()).days, "days ago"
rewrite_tag_db(entry)
