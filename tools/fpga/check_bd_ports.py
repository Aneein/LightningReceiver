import json

bd = r"D:\workspace\LightningReceiver\fpga\LightningReceiver\LightningReceiver.srcs\sources_1\bd\system\system.bd"
doc = json.load(open(bd, encoding="utf-8"))
design = doc["design"]
cells = design.get("components", {})
connected = set()
for nname, n in design.get("nets", {}).items():
    for p in n.get("ports", []):
        connected.add(p)
for nname, n in design.get("interface_nets", {}).items():
    for p in n.get("interface_ports", []):
        connected.add(p)

for cellname in ["axi_ad9361_0", "cmac_0", "ddr4_0", "clk_fabric", "fifo_cmac_tx_cdc", "fifo_cmac_rx_cdc"]:
    cell = cells.get(cellname, {})
    print("=" * 20, cellname, "=" * 20)
    for pname, p in cell.get("ports", {}).items():
        ref = cellname + "/" + pname
        status = "CONNECTED" if ref in connected else "** UNCONNECTED **"
        print("  {:<30} {:<8} {}".format(pname, p.get("direction", "?"), status))
    for iname, i in cell.get("interface_ports", {}).items():
        ref = cellname + "/" + iname
        status = "CONNECTED" if ref in connected else "** UNCONNECTED **"
        print("  {:<30} {:<8} {}".format(iname, i.get("mode", "?"), status))
    print()

print("=" * 20, "TOP-LEVEL PORTS", "=" * 20)
for pname, p in design.get("ports", {}).items():
    print("  {:<40} {:<8}".format(pname, p.get("direction", "?")))
for iname, i in design.get("interface_ports", {}).items():
    print("  {:<40} {:<8} (interface)".format(iname, i.get("mode", "?")))
