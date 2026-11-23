#!/usr/bin/env python3
"""M1 acceptance only. This report never configures or enables a runtime."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
GROUPS={'build':('verify-macos-build-m1.py','build-final.json','incomplete'),
        'product':('verify-macos-product-m1.py','product-final.json','passed')}


def required(script):
    spec=importlib.util.spec_from_file_location('m1_'+script.replace('-','_'),ROOT/'scripts'/script)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module.CASES


def assess(reports):
    failures=[];checks=0
    for group,(script,_,gate)in GROUPS.items():
        record=reports.get(group,{})
        for key,value in [('fixtureOnly',True),('installed',False),('signaturesVerifiedBeforeAndAfter',True),('temporaryArtifactsRemoved',True)]:
            if record.get(key)is not value:raise ValueError('Invalid evidence scope or cleanup: '+group+'.'+key)
        if record.get('gate')!=gate:failures.append(group+'.gate')
        for key in required(script):
            actual=record.get('cases',{}).get(key)
            if type(actual)is not bool:raise ValueError('Missing/non-boolean M1 observation: '+group+'.'+key)
            checks+=1
            if not actual:failures.append(group+'.'+key)
    if reports['product'].get('cases',{}).get('cleaned')is not True:raise ValueError('Native protected slots not cleaned')
    for field in ['productionRuntimeReady','publicExtensionsVerified']:
        if reports['product'].get(field)is not False:raise ValueError('M1 cannot approve extension execution')
    return dict(schema=1,gate='blocked'if failures else'M1-passed',failures=sorted(failures),checks=checks,
                M1Complete=not failures,M2Started=False,productionRuntimeReady=False,publicExtensionsVerified=False,
                candidate='restricted-JavaScriptCore',mode='build-only',
                scope='first-party-signed-build-receipt-and-install-transactions',
                remaining=['M2 command runtime','M3 UI and persistent content','M4 performance','M5 VM removal and product switch'])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence',type=Path,default=ROOT/'docs/evidence/macos-runtime-m1/final')
    p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    if args.report.exists():raise SystemExit('Refusing report overwrite')
    records={};hashes={}
    for group,(_,file,_)in GROUPS.items():
        body=(args.evidence/file).read_bytes();records[group]=json.loads(body);hashes[file]=hashlib.sha256(body).hexdigest()
    report=assess(records);report['evidenceSHA256']=hashes
    args.report.parent.mkdir(parents=True,exist_ok=True)
    with args.report.open('x')as f:json.dump(report,f,indent=2)
    print(json.dumps({'gate':report['gate'],'M1Complete':report['M1Complete'],'productionRuntimeReady':False}))
    return 0 if report['M1Complete']else 2


if __name__=='__main__':raise SystemExit(main())
