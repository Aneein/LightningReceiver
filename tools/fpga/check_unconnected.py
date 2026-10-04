import json, sys

bd = sys.argv[1] if len(sys.argv) > 1 else r"D:\workspace\LightningReceiver\fpga\LightningReceiver\LightningReceiver.srcs\sources_1\bd\system\system.bd"
with open(bd, "r", encoding="utf-8") as f:
    doc = json.load(f)

design = doc["design"]
cells = design.get("components", {})

# connected scalar pins: "cell/pin"
connected_pins = set()
for nname, n in design.get("nets", {}).items():
    for p in n.get("ports", []):
        connected_pins.add(p)

# connected interface refs: "cell/iface" (as written in interface_nets)
connected_ifaces = set()
for nname, n in design.get("interface_nets", {}).items():
    for p in n.get("interface_ports", []):
        connected_ifaces.add(p)

print("=== SCALAR PINS UNCONNECTED (nets) ===")
for cname in sorted(cells.keys()):
    cell_obj = cells[cname]
    for pname, p in cell_obj.get("ports", {}).items():
        ref = f"{cname}/{pname}"
        if ref not in connected_pins:
            print(f"  {cname:<16} {pname:<28} {p.get('direction','?'):<8}")

print()
print("=== INTERFACES UNCONNECTED (interface_nets) ===")
for cname in sorted(cells.keys()):
    cell_obj = cells[cname]
    for iname, i in cell_obj.get("interface_ports", {}).items():
        ref = f"{cname}/{iname}"
        if ref not in connected_ifaces:
            print(f"  {cname:<16} {iname:<28} {i.get('mode','?'):<8}")
