"""Choose an installed iPhone on iOS 26+, never silently test Liquid Glass on 18."""
import argparse
import json
import os
import re
import subprocess


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--legacy',action='store_true')
    parser.add_argument('--prepare',action='store_true',help='Boot the selected runtime with a finite startup timeout')
    args=parser.parse_args()
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','-j']))
    candidates=[]
    for runtime,items in devices['devices'].items():
        match=re.search(r'iOS-(\d+)-(\d+)',runtime)
        if not match:continue
        version=tuple(int(x) for x in match.groups())
        if (version[0]<26) != args.legacy:continue
        for item in items:
            if not item['name'].startswith('iPhone'):continue
            score=(version, item['name']=='iPhone 17 Pro', item['name']=='iPhone 16 Pro')
            candidates.append((score,item,runtime))
    if not candidates:raise SystemExit('Required iPhone simulator runtime is not installed')
    _,device,runtime=max(candidates,key=lambda x:x[0])
    if os.environ.get('GITHUB_ENV'):
        key='LEGACY_DEVICE_ID' if args.legacy else 'DEVICE_ID'
        with open(os.environ['GITHUB_ENV'],'a') as stream:
            stream.write(key+'='+device['udid']+'\nTEST_DEVICE_ID='+device['udid']+'\n')
    print(json.dumps({'device':device['name'],'runtime':runtime,'udid':device['udid']}),flush=True)
    if args.prepare:
        if device.get('state') != 'Booted':
            subprocess.run(['xcrun','simctl','boot',device['udid']],check=True,timeout=45)
        subprocess.run(['xcrun','simctl','bootstatus',device['udid'],'-b'],check=True,timeout=270)


if __name__=='__main__':main()
