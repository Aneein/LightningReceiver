import json

bd = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\LightningReceiver.srcs\sources_1\bd\system\system.bd"
doc = json.load(open(bd, encoding="utf-8"))
d = doc["design"]
print("=== nets touching xc_t_inc ===")
for nname, n in d.get("nets", {}).items():
    ps = n.get("ports", [])
    if any("xc_t_inc/In" in p for p in ps):
        print(f"  {nname}: {ps}")
print()
print("=== nets touching u_tele/inc / u_tele/clk / u_tele/rst_n ===")
for nname, n in d.get("nets", {}).items():
    ps = n.get("ports", [])
    if any("u_tele/" in p for p in ps):
        print(f"  {nname}: {ps}")
