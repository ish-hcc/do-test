"""cm-honeybee 소스 그룹 생성 본문을 만든다. 06-honeybee.sh register 가 부른다.

usage: hb-body.py kind ns infra.json key.pem source-vms.conf csp region nodegroup purpose sgname < (복호화된 credentials.yaml | 빈 입력)
kind 가 csp 면 stdin 의 credentials.yaml 에서 admin.<csp> 값을 credential 로 넣는다. 결과는 stdout 의 JSON 하나다.
"""
import sys, json
kind, ns, infra_path, key_path, conf, csp, region, ng, purpose, sgname = sys.argv[1:11]
infra = json.load(open(infra_path))
key = open(key_path).read()
names = {}
for line in open(conf):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    f = line.split()
    if f[2] == purpose:
        names[f"{ng}-{f[0]}"] = f[1]
conns = []
for n in sorted(infra["node"], key=lambda x: int(x["id"].rsplit("-", 1)[1])):
    if n["id"] not in names:
        continue
    c = {"name": f"{ns}-{names.get(n['id'], n['id'])}", "description": f"{n['id']} {n.get('cspResourceId','')}",
         "ip_address": n["publicIP"], "ssh_port": str(n.get("sshPort") or 22),
         "user": n.get("nodeUserName") or "cb-user", "private_key": key}
    if kind == "csp":
        c["resource_type"] = "vm"
        c["resource_id"] = n["cspResourceId"]
    conns.append(c)
body = {"name": sgname, "description": f"cm-migration-test {ns} {purpose} ({kind})", "type": "onprem" if kind == "onprem" else "csp",
        "connection_info": conns}
if kind == "csp":
    import yaml
    d = yaml.safe_load(sys.stdin) or {}
    kv = d["credentialholder"]["admin"][csp]
    body.update(provider_name=csp, region_name=region,
                credential=[{"key": k, "value": str(v)} for k, v in kv.items() if str(v or "").strip()])
json.dump(body, sys.stdout)
