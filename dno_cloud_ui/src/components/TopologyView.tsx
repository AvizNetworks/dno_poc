import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ChevronDown, ChevronRight, Globe, Network, Database, Server, Loader2 } from "lucide-react";

interface VPC {
  VpcId: string;
  Name: string | null;
}

interface Subnet {
  SubnetId: string;
  Name: string | null;
  CidrBlock: string;
  AvailableIpAddressCount: number;
}

interface Instance {
  InstanceId: string;
  Name: string | null;
  PrivateIpAddress?: string;
  PublicIpAddress?: string;
  State: string;
  LaunchTime?: string | null;
  Uptime?: string;
}

interface SubnetStatus {
  running: number;
  stopped: number;
  total: number;
}

export function TopologyView() {
  const [regions, setRegions] = useState<string[]>([]);
  const [vpcs, setVpcs] = useState<Record<string, VPC[]>>({});
  const [subnets, setSubnets] = useState<Record<string, Subnet[]>>({});
  const [instances, setInstances] = useState<Record<string, Instance[]>>({});
  const [subnetStatus, setSubnetStatus] = useState<Record<string, SubnetStatus>>({});
  const [expandedRegion, setExpandedRegion] = useState<string | null>(null);
  const [expandedVPC, setExpandedVPC] = useState<string | null>(null);
  const [expandedSubnet, setExpandedSubnet] = useState<string | null>(null);
  const [loading, setLoading] = useState<Record<string, boolean>>({ initial: true });

  const apiFetch = (path: string) => fetch(`/api${path}`).then((res) => res.json());

  useEffect(() => {
    async function preloadTopology() {
      setLoading((prev) => ({ ...prev, initial: true }));
      try {
        const regionsList = await apiFetch("/regions");
        setRegions(regionsList);

        const allVPCs: Record<string, VPC[]> = {};
        const allSubnets: Record<string, Subnet[]> = {};

        await Promise.all(
          regionsList.map(async (region) => {
            const regionVPCs = await apiFetch(`/vpcs?region=${region}`);
            allVPCs[region] = regionVPCs;

            await Promise.all(
              regionVPCs.map(async (vpc) => {
                const vpcSubnets = await apiFetch(`/subnets?region=${region}&vpc_id=${vpc.VpcId}`);
                allSubnets[vpc.VpcId] = vpcSubnets;

                await Promise.all(
                  vpcSubnets.map(async (subnet) => {
                    const instData: any[] = await apiFetch(`/instances_in_subnet?region=${region}&subnet_id=${subnet.SubnetId}`);
                    const instDetails = await Promise.all(instData.map(inst => fetchInstanceDetails(region, inst.InstanceId)));

                    setInstances((prev) => ({ ...prev, [subnet.SubnetId]: instDetails }));

                    const running = instDetails.filter(i => i.State === "running").length;
                    const stopped = instDetails.filter(i => i.State === "stopped").length;
                    const total = instDetails.length;
                    setSubnetStatus((prev) => ({ ...prev, [subnet.SubnetId]: { running, stopped, total } }));
                  })
                );
              })
            );
          })
        );

        setVpcs(allVPCs);
        setSubnets(allSubnets);
      } catch (err) {
        console.error("Failed to load topology:", err);
      } finally {
        setLoading((prev) => ({ ...prev, initial: false }));
      }
    }

    preloadTopology();
  }, []);

  const fetchInstanceDetails = async (region: string, instanceId: string) => {
    const formatUptime = (seconds: number) => {
      const days = Math.floor(seconds / 86400);
      const hours = Math.floor((seconds % 86400) / 3600);
      const minutes = Math.floor((seconds % 3600) / 60);
      if (days > 0) return `${days}d ${hours}h`;
      if (hours > 0) return `${hours}h ${minutes}m`;
      return `${minutes}m`;
    };

    try {
      const data = await apiFetch(`/instance_details?region=${region}&instance_id=${instanceId}`);
      const nameTag = data.Tags?.find((t: any) => t.Key === "Name");
      const launchTime = data.LaunchTime ? new Date(data.LaunchTime) : null;
      let uptime = "N/A";

      if (launchTime && data.State?.Name === "running") {
        const diffSec = Math.floor((new Date().getTime() - launchTime.getTime()) / 1000);
        uptime = formatUptime(diffSec);
      }

      return {
        Name: nameTag?.Value ?? instanceId,
        PrivateIpAddress: data.PrivateIpAddress ?? "-",
        PublicIpAddress: data.PublicIpAddress ?? "-",
        State: data.State?.Name?.toLowerCase() ?? "unknown",
        LaunchTime: data.LaunchTime ?? null,
        Uptime: uptime,
      };
    } catch {
      return {
        Name: instanceId,
        PrivateIpAddress: "-",
        PublicIpAddress: "-",
        State: "unknown",
        LaunchTime: null,
        Uptime: "N/A",
      };
    }
  };

  const toggleSubnet = (subnetId: string) => {
    setExpandedSubnet(expandedSubnet === subnetId ? null : subnetId);
  };

  useEffect(() => {
    const interval = setInterval(() => {
      setInstances((prev) => {
        const updated = { ...prev };
        for (const subnetId of Object.keys(updated)) {
          updated[subnetId] = updated[subnetId].map((inst) => {
            if (!inst.LaunchTime || inst.State !== "running") return inst;
            const diffMs = new Date().getTime() - new Date(inst.LaunchTime).getTime();
            const hours = Math.floor(diffMs / (1000 * 60 * 60));
            const mins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60));
            return { ...inst, Uptime: `${hours}h ${mins}m` };
          });
        }
        return updated;
      });
    }, 60000);
    return () => clearInterval(interval);
  }, []);

  const getStateBadgeColor = (state: string) => {
    switch (state) {
      case "running": return "bg-green-600 text-white";
      case "stopped": return "bg-gray-600 text-white";
      case "stopping": return "bg-orange-600 text-white";
      default: return "bg-muted text-muted-foreground";
    }
  };

  const Skeleton = () => <div className="h-3 w-24 bg-muted rounded animate-pulse" />;

  return (
    <div className="min-h-screen bg-background p-4 sm:p-6 pb-32">
      <div className="container mx-auto max-w-7xl px-2 sm:px-6">
        <Card className="w-full border-border bg-card/50 backdrop-blur-sm">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Network className="h-5 w-5 text-primary" /> Network Topology
            </CardTitle>
          </CardHeader>

          <CardContent className="space-y-3">
            {loading.initial && (
              <div className="flex items-center gap-2 p-4">
                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                <span className="text-sm text-muted-foreground">Loading VPC Topology...</span>
              </div>
            )}

            {regions.map((region) => (
              <div key={region} className="border border-border rounded-lg w-full">
                <div
                  onClick={() => setExpandedRegion(expandedRegion === region ? null : region)}
                  className="flex items-center gap-3 p-4 cursor-pointer hover:bg-muted/50 transition-colors"
                >
                  {expandedRegion === region ? <ChevronDown className="h-5 w-5 text-primary" /> : <ChevronRight className="h-5 w-5 text-muted-foreground" />}
                  <Globe className="h-5 w-5 text-secondary" />
                  <span className="font-semibold truncate">{region}</span>
                  <Badge variant="outline" className="ml-auto">{vpcs[region]?.length ?? 0} VPCs</Badge>
                </div>

                {expandedRegion === region && (
                  <div className="pl-8 pr-4 pb-4 space-y-2">
                    {vpcs[region]?.map((vpc) => (
                      <div key={vpc.VpcId} className="border border-border rounded-lg">
                        <div
                          onClick={() => setExpandedVPC(expandedVPC === vpc.VpcId ? null : vpc.VpcId)}
                          className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                        >
                          {expandedVPC === vpc.VpcId ? <ChevronDown className="h-4 w-4 text-primary" /> : <ChevronRight className="h-4 w-4 text-muted-foreground" />}
                          <Network className="h-4 w-4 text-accent" />
                          <div className="flex-1 truncate">
                            <div className="font-medium truncate">{vpc.Name ?? vpc.VpcId}</div>
                            <div className="text-xs text-muted-foreground truncate">{vpc.VpcId}</div>
                          </div>
                          <Badge variant="outline">{subnets[vpc.VpcId]?.length ?? 0} Subnets</Badge>
                        </div>

                        {expandedVPC === vpc.VpcId && (
                          <div className="pl-8 pr-3 pb-3 space-y-2">
                            {subnets[vpc.VpcId]?.map((subnet) => (
                              <div key={subnet.SubnetId} className="border border-border rounded-lg">
                                <div
                                  onClick={() => toggleSubnet(subnet.SubnetId)}
                                  className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                                >
                                  {expandedSubnet === subnet.SubnetId ? <ChevronDown className="h-4 w-4 text-primary" /> : <ChevronRight className="h-4 w-4 text-muted-foreground" />}
                                  <Database className="h-4 w-4 text-primary" />
                                  <div className="flex-1 truncate">
                                    <div className="font-medium text-sm truncate">{subnet.Name ?? subnet.SubnetId}</div>
                                    <div className="text-xs text-muted-foreground truncate">
                                      {subnet.SubnetId} • {subnet.CidrBlock} • Total: {subnetStatus[subnet.SubnetId]?.total ?? 0} • {subnetStatus[subnet.SubnetId]?.running ?? 0} running • {subnetStatus[subnet.SubnetId]?.stopped ?? 0} stopped 
                                    </div>
                                  </div>
                                  <Badge variant="default" className="text-xs">{subnet.AvailableIpAddressCount} IPs</Badge>
                                </div>

                                {expandedSubnet === subnet.SubnetId && (
                                  <div className="pl-8 pr-3 pb-3 space-y-2">
                                    {loading[`subnet-${subnet.SubnetId}`] && (
                                      <div className="flex items-center gap-2">
                                        <Loader2 className="h-4 w-4 animate-spin text-primary" />
                                        <span>Loading Instances...</span>
                                      </div>
                                    )}

                                    {instances[subnet.SubnetId]?.map((inst) => (
                                      <div key={inst.InstanceId} className="flex items-center gap-3 p-2 border rounded hover:bg-muted/30 transition-colors">
                                        <Server className="h-4 w-4 text-success" />
                                        <div className="flex-1 truncate">
                                          <div className="text-sm font-medium truncate">{inst.State === "loading" ? <Skeleton /> : inst.Name}</div>
                                          <div className="text-xs text-muted-foreground truncate">
                                            {inst.InstanceId} • {inst.PrivateIpAddress} • {inst.PublicIpAddress}
                                            {inst.LaunchTime && (
                                              <>
                                                {" • "} <span className="text-xs text-muted-foreground">Launched: {new Date(inst.LaunchTime).toLocaleString()}</span>
                                                {" • "} <span className="text-xs text-blue-600">Uptime: {inst.Uptime}</span>
                                              </>
                                            )}
                                          </div>
                                        </div>
                                        {inst.State === "loading" ? <Skeleton /> : <Badge className={getStateBadgeColor(inst.State)}>{inst.State}</Badge>}
                                      </div>
                                    ))}
                                  </div>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
