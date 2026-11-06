"""honeybee CSP 수집 결과를 tumblebug 이 아는 실제 값과 대조해 "Cloud-Migrator 세부 목표" CM-Honeybee 1~8행을 판정한다.
10-csp-collect.sh judge 가 부른다.

usage: csp-judge.py <csp> <honeybee csp 섹션 json|-> <tumblebug 값 json|-> [<csp> ...]
  honeybee json: GET /source_group/{sg}/connection_info/{conn}/infra 의 .csp
  tumblebug json: {infra, node, vnet, sshkey, sgs:[...], disks:[...]} (10-csp-collect.sh 가 만든다)

판정: O = 값이 있고 tumblebug 값과 맞음, △ = 일부만 있거나 tumblebug 값과 다름, X = 비었음.
"""
import json
import os
import sys

ROWS = ["1 Image", "2 Spec", "3 VPC", "4 Subnet", "5 SG", "6 KeyPair", "7 VM", "8 Disk"]
NO_CIDR = "does not support"  # gcp·ibm·openstack 은 VPC 에 CIDR 이 없다고 cb-spider 가 이 문구를 넣는다


def load(p):
    if p == "-" or not os.path.exists(p):
        return None
    try:
        return json.load(open(p))
    except ValueError:
        return None


def ids(*objs, keys=("cspResourceName", "cspResourceId")):
    out = set()
    for o in objs:
        if isinstance(o, dict):
            out |= {str(o.get(k)) for k in keys if o.get(k)}
        elif o:
            out.add(str(o))
    return out


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def judge(h, t):
    """-> [(mark, note)] * 8"""
    node = (t or {}).get("node") or {}
    vnet = (t or {}).get("vnet") or {}
    net = h.get("network") or {}
    vpc = net.get("vpc") or {}
    r = []

    # 1 Image: image, image_detail
    img, det = h.get("image"), h.get("image_detail") or {}
    want = ids(node.get("cspImageName"), node.get("imageId"))
    got = ids(img, det.get("id"), det.get("name"))
    if not img:
        r.append(("X", "image 없음"))
    elif not (det.get("id") or det.get("name")):
        r.append(("△", "image_detail 없음"))
    elif t and not (want & got):
        r.append(("△", f"tb {sorted(want)} != hb {img}"))
    else:
        r.append(("O", det.get("os_distribution", "")[:40]))

    # 2 Spec: vm_spec, vm_spec_detail.vcpus/memory_mib
    spec, sd = h.get("vm_spec"), h.get("vm_spec_detail") or {}
    ts = node.get("spec") or {}
    if not spec:
        r.append(("X", "vm_spec 없음"))
    elif not (sd.get("vcpus") and sd.get("memory_mib")):
        r.append(("△", "vcpus/memory_mib 없음"))
    elif t and (spec != node.get("cspSpecName") or num(sd["vcpus"]) != num(ts.get("vCPU"))
                or abs(num(sd["memory_mib"]) - num(ts.get("memoryGiB")) * 1024) > num(ts.get("memoryGiB")) * 1024 * 0.1):
        r.append(("△", f"tb {node.get('cspSpecName')} {ts.get('vCPU')}c/{ts.get('memoryGiB')}G != hb {spec} {sd['vcpus']}c/{sd['memory_mib']}MiB"))
    else:
        r.append(("O", f"{spec} {sd['vcpus']}c/{sd['memory_mib']}MiB"))

    # 3 VPC: network.vpc.name/cidr
    name, cidr = vpc.get("name"), vpc.get("cidr") or ""
    if not name:
        r.append(("X", "vpc 없음"))
    elif not cidr:
        r.append(("△", "cidr 없음"))
    elif t and name not in ids(vnet, node.get("cspVNetId")):
        r.append(("△", f"vpc 이름 {name} 이 tb vNet 과 다름"))
    elif NO_CIDR in cidr:
        r.append(("O", "CSP 에 VPC CIDR 개념 없음"))
    elif t and vnet.get("cidrBlock") and cidr != vnet.get("cidrBlock"):
        r.append(("△", f"cidr tb {vnet.get('cidrBlock')} != hb {cidr}"))
    else:
        r.append(("O", cidr))

    # 4 Subnet: network.subnet, vpc.subnets[].cidr
    sub, subs = net.get("subnet"), vpc.get("subnets") or []
    tsubs = vnet.get("subnetInfoList") or []
    tsub_ids = ids(*tsubs, node.get("cspSubnetId"))
    if not sub:
        r.append(("X", "subnet 없음"))
    elif not any(s.get("cidr") for s in subs):
        r.append(("△", "subnets[].cidr 없음"))
    elif t and tsubs and sub not in tsub_ids:
        r.append(("△", f"subnet {sub} 이 tb subnet 과 다름"))
    else:
        tc = {s.get("ipv4_CIDR") for s in tsubs}
        hc = {s.get("cidr") for s in subs}
        if t and tc and not tc <= hc:
            r.append(("△", f"cidr tb {sorted(tc)} != hb {sorted(hc)}"))
        else:
            r.append(("O", f"{len(subs)}개"))

    # 5 SG: security_groups[].rules
    sgs = net.get("security_groups") or []
    tsg = (t or {}).get("sgs") or []
    if not sgs:
        r.append(("X", "security_groups 없음"))
    elif not all(s.get("rules") for s in sgs):
        r.append(("△", "rules 없는 SG 있음"))
    elif t and tsg and not ({s.get("name") for s in sgs} & ids(*tsg)):
        r.append(("△", "SG 이름이 tb 와 다름"))
    else:
        tn = sum(len(s.get("firewallRules") or []) for s in tsg)
        hn = sum(len(s.get("rules") or []) for s in sgs)
        r.append(("O", f"규칙 hb {hn} / tb {tn}" if tsg else f"규칙 {hn}"))

    # 6 KeyPair: keypair.name
    kp = (h.get("keypair") or {}).get("name")
    if not kp:
        r.append(("X", "keypair 없음"))
    elif t and kp not in ids((t or {}).get("sshkey"), node.get("cspSshKeyId")):
        r.append(("△", f"tb sshKey {sorted(ids((t or {}).get('sshkey'), node.get('cspSshKeyId')))} != hb {kp}"))
    else:
        r.append(("O", kp))

    # 7 VM: name/id/ip/status
    miss = [k for k in ("name", "id", "status") if not h.get(k)]
    if not (h.get("public_ip") or h.get("private_ip")):
        miss.append("ip")
    diff = []
    if t:
        if h.get("id") and h.get("id") not in ids(node):
            diff.append("id")
        if h.get("private_ip") and node.get("privateIP") and h.get("private_ip") != node.get("privateIP"):
            diff.append("private_ip")
        if h.get("public_ip") and node.get("publicIP") and h.get("public_ip") != node.get("publicIP"):
            diff.append("public_ip")
    if len(miss) == 4:
        r.append(("X", "VM 값 없음"))
    elif miss or diff:
        r.append(("△", " ".join([f"{m} 없음" for m in miss] + [f"{d} 다름" for d in diff])))
    else:
        r.append(("O", f"{h.get('status')}"))

    # 8 Disk: root_disk, data_disk_details[].size
    root = num((h.get("root_disk") or {}).get("size"))
    dd = sorted(num(d.get("size")) for d in h.get("data_disk_details") or [])
    tdd = sorted(num(d.get("diskSize")) for d in (t or {}).get("disks") or [])
    if not root and not dd:
        r.append(("X", "disk 없음"))
    elif not root or (tdd and dd != tdd) or (not dd and (h.get("data_disks") or tdd)):
        r.append(("△", f"root {root:g}GB, data hb {[f'{x:g}' for x in dd]} / tb {[f'{x:g}' for x in tdd]}"))
    else:
        r.append(("O", f"root {root:g}GB, data {[f'{x:g}' for x in dd]}GB"))
    return r


def main(argv):
    if len(argv) % 3 or not argv:
        sys.exit(__doc__)
    results = []
    for i in range(0, len(argv), 3):
        csp, hp, tp = argv[i:i + 3]
        h, t = load(hp), load(tp)
        if not h:
            if hp == "-":
                results.append((csp, [("-", "소스 그룹·연결 없음 (register 전)")] * 8, t))
            else:
                results.append((csp, [("X", "honeybee csp 섹션 비었음 (collect 전이거나 실패)")] * 8, t))
        else:
            results.append((csp, judge(h, t), t))
    print(f"{'csp':10} " + " ".join(f"{r.split()[1]:>8}" for r in ROWS) + "  tb 대조")
    for csp, r, t in results:
        print(f"{csp:10} " + " ".join(f"{m:>8}" for m, _ in r) + f"  {'O' if t else '-(tb VM 못 찾음)'}")
    print("\nO 값 있고 tumblebug 과 맞음 / △ 일부만 있거나 tumblebug 과 다름 / X 비었음 / - 등록 안 됨")
    print("tb 대조가 - 면 tumblebug 에서 그 VM 을 못 찾아 값이 있는지만 본 것이다")
    print("\n세부 (O 가 아닌 칸, 그리고 csp 마다 값 요약):")
    for csp, r, _ in results:
        bad = [(row, m, note) for row, (m, note) in zip(ROWS, r) if m != "O"]
        if bad and all(m == "-" for _, m, _ in bad) and len(bad) == 8:
            print(f"  {csp:10} {bad[0][2]}")
            continue
        for row, m, note in bad:
            print(f"  {csp:10} {row:10} {m}  {note}")
        ok = {row.split()[1]: note for row, (m, note) in zip(ROWS, r) if m == "O" and note}
        if ok:
            print(f"  {csp:10} " + " | ".join(f"{k} {v}" for k, v in ok.items() if k in ("Spec", "VPC", "Disk")))
    tested = [m for _, r, _ in results for m, _ in r if m != "-"]
    sys.exit(0 if tested and all(m == "O" for m in tested) else 1)


if __name__ == "__main__":
    main(sys.argv[1:])
