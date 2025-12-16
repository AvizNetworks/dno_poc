import { useState, useEffect, useCallback } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { Server, Download, Trash2, Square, Loader2, RefreshCw } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

type VPC = { VpcId: string; Name?: string };
type Subnet = { SubnetId: string; Name?: string };
type Instance = { InstanceId: string; Name?: string };

type DeployedNode = {
  id: string;
  name: string;
  region: string;
  vpc: string;
  ip: string;
  publicIp?: string;
  status: string;
  deployedAt?: string;
  hostname?: string;
};

export function DeployAvizNode() {
  const { toast } = useToast();

  const [selectedRegion, setSelectedRegion] = useState("");
  const [selectedVPC, setSelectedVPC] = useState("");
  const [selectedInstance, setSelectedInstance] = useState("");

  const [regions, setRegions] = useState<string[]>([]);
  const [vpcs, setVPCs] = useState<VPC[]>([]);
  const [subnets, setSubnets] = useState<Subnet[]>([]);
  const [instances, setInstances] = useState<Instance[]>([]);
  const [instanceDetails, setInstanceDetails] = useState<any>(null);

  const [actionLoading, setActionLoading] = useState<string | null>(null);
  const [deployedNodes, setDeployedNodes] = useState<DeployedNode[]>([]);
  const [isDeploying, setIsDeploying] = useState(false);
  const [nodesLoading, setNodesLoading] = useState(false);
  const [nodesError, setNodesError] = useState<string | null>(null);

  const apiFetch = useCallback(async (path: string, opts?: RequestInit) => {
    const res = await fetch(`/api${path}`, opts);
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(text || res.statusText);
    }
    const ct = res.headers.get("content-type") || "";
    if (ct.includes("application/json")) return res.json();
    return null;
  }, []);

  const loadDeployedNodes = useCallback(async () => {
    setNodesLoading(true);
    setNodesError(null);
    try {
      const data = await apiFetch("/asn/deployed");
      setDeployedNodes(data || []);
    } catch (err) {
      const errorMsg = String(err);
      setNodesError(errorMsg);
      console.error("Failed to load deployed nodes:", err);
    } finally {
      setNodesLoading(false);
    }
  }, [apiFetch]);

  const handleStopASN = async (instanceId: string) => {
    try {
      setActionLoading(instanceId);
      await apiFetch(`/asn/stop`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ instance_id: instanceId }),
      });
      toast({ title: "vASN stopped", description: `Stopped ASN on ${instanceId}` });
      await loadDeployedNodes(); 
    } catch (err) {
      toast({ title: "Stop error", description: String(err), variant: "destructive" });
    } finally {
      setActionLoading(null);
    }
  };

  const handleDeleteAvizNode = async (instanceId: string) => {
    try {
      setActionLoading(instanceId);
      await apiFetch(`/asn/delete?instance_id=${instanceId}`, { method: "POST" });
      toast({ title: "Deleted", description: `Deleted vASN ${instanceId}` });
      await loadDeployedNodes(); 
    } catch (err) {
      toast({ title: "Delete error", description: String(err), variant: "destructive" });
    } finally {
      setActionLoading(null);
    }
  };

  useEffect(() => {
    apiFetch("/regions")
      .then((data) => setRegions(data || []))
      .catch((err) => toast({ title: "Region load error", description: String(err), variant: "destructive" }));
      loadDeployedNodes();
  }, [apiFetch, toast, loadDeployedNodes]);

  useEffect(() => {
    if (!selectedRegion) {
      setVPCs([]);
      setSelectedVPC("");
      setSubnets([]);
      setInstances([]);
      return;
    }
    apiFetch(`/vpcs?region=${encodeURIComponent(selectedRegion)}`)
      .then((data) => setVPCs(data || []))
      .catch((err) => toast({ title: "VPC load error", description: String(err), variant: "destructive" }));
  }, [selectedRegion, apiFetch, toast]);

  useEffect(() => {
    if (!selectedRegion || !selectedVPC) {
      setSubnets([]);
      setInstances([]);
      setSelectedInstance("");
      return;
    }
    apiFetch(`/subnets?region=${encodeURIComponent(selectedRegion)}&vpc_id=${encodeURIComponent(selectedVPC)}`)
      .then((data) => setSubnets(data || []))
      .catch((err) => toast({ title: "Subnet load error", description: String(err), variant: "destructive" }));
  }, [selectedRegion, selectedVPC, apiFetch, toast]);

  useEffect(() => {
    if (!selectedRegion || subnets.length === 0) {
      setInstances([]);
      setSelectedInstance("");
      return;
    }

    let mounted = true;
    const loadInstances = async () => {
      let allInstances: Instance[] = [];
      for (const subnet of subnets) {
        try {
          const data = await apiFetch(
            `/instances_in_subnet?region=${encodeURIComponent(selectedRegion)}&subnet_id=${encodeURIComponent(subnet.SubnetId)}`
          );
          allInstances = [...allInstances, ...(data || [])];
        } catch (err) {
          console.error("Instance fetch error:", err);
        }
      }
      if (mounted) setInstances(allInstances);
    };
    loadInstances();
    return () => { mounted = false; };
  }, [selectedRegion, subnets, apiFetch]);

  useEffect(() => {
    if (!selectedInstance || !selectedRegion) {
      setInstanceDetails(null);
      return;
    }

    apiFetch(`/instance_details?region=${encodeURIComponent(selectedRegion)}&instance_id=${encodeURIComponent(selectedInstance)}`)
      .then((data) => setInstanceDetails(data || null))
      .catch((err) => toast({ title: "Instance details load error", description: String(err), variant: "destructive" }));
  }, [selectedInstance, selectedRegion, apiFetch, toast]);

  const handleDeployAvizNode = async () => {
    if (!selectedRegion || !selectedVPC || !selectedInstance) {
      toast({
        title: "Missing configuration",
        description: "Please select region, VPC, and instance",
        variant: "destructive",
      });
      return;
    }

    setIsDeploying(true);

    try {
      const response = await apiFetch("/asn/deploy", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          region: selectedRegion,
          vpc_id: selectedVPC,
          instance_id: selectedInstance,
        }),
      });

      toast({
        title: "Deployment Successful",
        description: `Virtual Aviz Service Node deployed on ${selectedInstance}`,
      });

      await loadDeployedNodes();

      setSelectedInstance("");
      setInstanceDetails(null);

    } catch (err: any) {
      toast({
        title: "Deployment Failed",
        description: err.message || String(err),
        variant: "destructive",
      });
    } finally {
      setIsDeploying(false);
    }
  };

  return (
    <div className="flex flex-col gap-6 h-full overflow-y-auto p-2">

      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Server className="h-5 w-5 text-accent" /> Deploy Virtual Aviz Service Node
          </CardTitle>
          <CardDescription>Deploy Virtual Aviz Service Node EC2 instance to receive mirrored traffic</CardDescription>
        </CardHeader>

        <CardContent className="space-y-4">

          <div className="grid gap-4 md:grid-cols-3">
            <div className="space-y-2">
              <Label>Select Region</Label>
              <Select value={selectedRegion} onValueChange={setSelectedRegion}>
                <SelectTrigger><SelectValue placeholder="Choose a region" /></SelectTrigger>
                <SelectContent>
                  {regions.map((r) => <SelectItem key={r} value={r}>{r}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Select VPC</Label>
              <Select value={selectedVPC} onValueChange={setSelectedVPC} disabled={vpcs.length === 0}>
                <SelectTrigger><SelectValue placeholder="Choose a VPC" /></SelectTrigger>
                <SelectContent>
                  {vpcs.map((v) => (
                    <SelectItem key={v.VpcId} value={v.VpcId}>
                      {v.Name || v.VpcId}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Source Instance</Label>
              <Select value={selectedInstance} onValueChange={setSelectedInstance} disabled={instances.length === 0}>
                <SelectTrigger><SelectValue placeholder="Choose an instance" /></SelectTrigger>
                <SelectContent>
                  {instances.map((i) => (
                    <SelectItem key={i.InstanceId} value={i.InstanceId}>
                      {i.Name || i.InstanceId}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="space-y-1 text-sm mt-2">
            {[
              "Flow Management",
              "Deep Packet Inspection (DPI)",
              "KPI Analysis",
              "Real-time Monitoring",
            ].map((cap) => (
              <div key={cap} className="flex items-center gap-2">
                <div className="h-1.5 w-1.5 rounded-full bg-primary" />
                <span>{cap}</span>
              </div>
            ))}
          </div>

          {instanceDetails && (
            <div className="p-3 rounded border border-border bg-muted/20 space-y-2 text-sm mt-3">

              <div className="flex justify-between">
                <span className="text-muted-foreground">Instance Type:</span>
                <span className="font-medium">{instanceDetails.InstanceType}</span>
              </div>

              <div className="flex justify-between">
                <span className="text-muted-foreground">vCPUs:</span>
                <span className="font-medium">{instanceDetails.CpuOptions?.CoreCount || "-"}</span>
              </div>

              <div className="flex justify-between">
                <span className="text-muted-foreground">Private IP:</span>
                <span className="font-medium">{instanceDetails.PrivateIpAddress || "-"}</span>
              </div>

              <div className="flex justify-between">
                <span className="text-muted-foreground">Public IP:</span>
                <span className="font-medium">{instanceDetails.PublicIpAddress || "-"}</span>
              </div>

              <div className="flex justify-between">
                <span className="text-muted-foreground">MAC Address:</span>
                <span className="font-medium">{instanceDetails.NetworkInterfaces?.[0]?.MacAddress || "-"}</span>
              </div>

              <div className="flex justify-between">
                <span className="text-muted-foreground">Platform:</span>
                <span className="font-medium">{instanceDetails.PlatformDetails || "-"}</span>
              </div>

              <div className="mt-2">
                <span className="text-muted-foreground font-medium">Network Interfaces (ENIs):</span>
                <div className="mt-1 space-y-1">
                  {instanceDetails.NetworkInterfaces?.map((eni: any) => (
                    <div key={eni.NetworkInterfaceId} className="flex justify-between gap-2 border rounded p-2 bg-background/20">
                      <span className="font-mono text-xs">
                        {eni.Description || "(null)"} 
                      </span>
                      <span className="font-mono text-xs text-muted-foreground">
                        {eni.NetworkInterfaceId}
                      </span>
                    </div>
                  )) || <span className="text-muted-foreground">No ENIs attached</span>}
                </div>
              </div>

            </div>
          )}

          <Button onClick={handleDeployAvizNode} className="w-full mt-2" disabled={isDeploying}>
            {isDeploying ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Deploying...
              </>
            ) : (
              <>
                <Download className="h-4 w-4 mr-2" />
                Deploy Virtual Aviz Service Node
              </>
            )}
          </Button>

        </CardContent>
      </Card>

      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <div className="flex items-center justify-between w-full">
            <div>
              <CardTitle>Deployed Virtual Aviz Service Nodes</CardTitle>
              <CardDescription>List of all deployed Virtual Aviz Service Nodes across regions</CardDescription>
            </div>
            <Button
              onClick={loadDeployedNodes}
              size="sm"
              disabled={nodesLoading || actionLoading !== null}
              className="ml-4"
            >
              <RefreshCw className="h-4 w-4 mr-2" /> Refresh
            </Button>
          </div>
        </CardHeader>

        <CardContent className="overflow-x-auto">
          {nodesLoading ? (
            <div className="p-4">Loading deployed nodes…</div>
          ) : nodesError ? (
            <div className="p-4 text-destructive">Error: {nodesError}</div>
          ) : deployedNodes.length === 0 ? (
            <div className="p-4 text-muted-foreground">No Virtual Aviz Service Nodes deployed yet.</div>
          ) : (
            <div className="rounded-lg border border-border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Instance ID</TableHead>
                    <TableHead>Name</TableHead>
                    <TableHead>Region</TableHead>
                    <TableHead>VPC</TableHead>
                    <TableHead>IP Address</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>

              <TableBody>
                {deployedNodes.map((node) => (
                  <TableRow key={node.id}>
                    <TableCell className="font-mono text-xs">{node.id}</TableCell>
                    <TableCell>{node.name}</TableCell>
                    <TableCell>{node.region}</TableCell>
                    <TableCell className="font-mono text-xs">{node.vpc}</TableCell>
                    <TableCell className="font-mono text-xs">{node.ip}</TableCell>

                    <TableCell>
                        <Badge className={node.status === "Running" ? "bg-success text-background" : "bg-muted"}>
                          {node.status}
                        </Badge>
                    </TableCell>

                    <TableCell className="flex gap-2 justify-end">

                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button
                            size="sm"
                            variant="ghost"
                            className="h-7 w-7 p-0"
                            disabled={node.status !== "Running" || actionLoading === node.id}
                            onClick={() => handleStopASN(node.id)}
                          >
                            {actionLoading === node.id ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              <Square className="h-4 w-4" />
                            )}
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Stop vASN</TooltipContent>
                      </Tooltip>

                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button
                            size="sm"
                            variant="ghost"
                            className="h-7 w-7 p-0"
                            disabled={actionLoading === node.id}
                            onClick={() => handleDeleteAvizNode(node.id)}
                          >
                            {actionLoading === node.id ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              <Trash2 className="h-4 w-4" />
                            )}
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Delete vASN</TooltipContent>
                      </Tooltip>

                    </TableCell>
                  </TableRow>
              ))}
              </TableBody>
            </Table>
          </div>
        )}
        </CardContent>
      </Card>

    </div>
  );
}
