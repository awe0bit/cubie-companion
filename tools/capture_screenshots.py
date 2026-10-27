"""Capture real native simulator UI from debug-only, network-free demo launch mode."""
import argparse
from pathlib import Path
import subprocess
import time

BUNDLE='org.corenest.app'


def call(*args,check=True):
    return subprocess.run(['xcrun','simctl',*args],check=check,capture_output=True,text=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--device',required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    call('boot',args.device,check=False)
    call('bootstatus',args.device,'-b')
    call('install',args.device,str(args.app))
    call('status_bar',args.device,'override','--time','9:41','--dataNetwork','wifi',
         '--wifiMode','active','--wifiBars','3','--batteryState','charged','--batteryLevel','100')
    for appearance in ['light','dark']:
        for tab in ['overview','services','devices','settings']:
            call('terminate',args.device,BUNDLE,check=False)
            call('launch',args.device,BUNDLE,'--ui-testing','--preview-tab',tab,'--preview-appearance',appearance)
            time.sleep(10)  # Cold native/runtime startup must finish before taking a screenshot.
            call('io',args.device,'screenshot',str(args.output/(tab+'-'+appearance+'.png')))
    for appearance in ['light','dark']:
        call('terminate',args.device,BUNDLE,check=False)
        call('launch',args.device,BUNDLE,'--ui-testing','--preview-tab','devices','--preview-detail','binding','--preview-appearance',appearance)
        time.sleep(10)
        call('io',args.device,'screenshot',str(args.output/('binding-'+appearance+'.png')))
    for appearance in ['light','dark']:
        call('terminate',args.device,BUNDLE,check=False)
        call('launch',args.device,BUNDLE,'--ui-testing','--preview-appearance',appearance)
        time.sleep(10)
        call('io',args.device,'screenshot',str(args.output/('welcome-'+appearance+'.png')))
    call('terminate',args.device,BUNDLE,check=False)
    call('launch',args.device,BUNDLE,'--ui-testing','--preview-tab','settings','--preview-appearance','light',
         '-UIPreferredContentSizeCategoryName','UICTContentSizeCategoryAccessibilityXXXL')
    time.sleep(10)
    call('io',args.device,'screenshot',str(args.output/'settings-accessibility.png'))
    for appearance in ['light','dark']:
        call('terminate',args.device,BUNDLE,check=False)
        call('launch',args.device,BUNDLE,'--ui-testing','--preview-tab','settings','--preview-detail','developer','--preview-appearance',appearance)
        time.sleep(10)
        call('io',args.device,'screenshot',str(args.output/('developer-'+appearance+'.png')))
    print('Captured 15 real simulator screenshots; all displayed data are demo fixtures.')


if __name__=='__main__':main()
