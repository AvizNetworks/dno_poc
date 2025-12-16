import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ChevronDown, ChevronRight, Globe, Network, Database, Server, Loader2 } from "lucide-react";

interface Instance {
  InstanceId: string;
  Name: string;
  PrivateIpAddress: string;
  PublicIpAddress: string;
  State: string;
  LaunchTime: string | null;
  Uptime?: string;
}

interface Subnet {
  SubnetId: string;
  Name: string | null;
  CidrBlock: string;
  AvailableIpAddressCount: number;
  Instances: Instance[];
  InstanceCounts: {
    total: number;
    running: number;
    stopped: number;
  };
}

interface VPC {
  VpcId: string;
  Name: string | null;
  Subnets: Record<string, Subnet>;
}

interface TopologyData {
  Region: string;
  VPCs: VPC[];
}

interface VPCPreview {
  VpcId: string;
  Name: string | null;
}

export function TopologyView() {
  const [regions, setRegions] = useState<string[]>([]);
  const [vpcPreviews, setVpcPreviews] = useState<Record<string, VPCPreview[]>>({});
  const [topologyData, setTopologyData] = useState<Record<string, TopologyData>>({});
  const [expandedRegion, setExpandedRegion] = useState<string | null>(null);
  const [expandedVPC, setExpandedVPC] = useState<string | null>(null);
  const [expandedSubnet, setExpandedSubnet] = useState<string | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [loadingRegions, setLoadingRegions] = useState<Record<string, boolean>>({});

  const apiFetch = (path: string) => fetch(`/api${path}`).then((res) => res.json());

  const calculateUptime = (launchTime: string | null, state: string): string => {
    if (!launchTime || state !== "running") return "N/A";
    
    const launchDate = new Date(launchTime);
    const now = new Date();
    const diffMs = now.getTime() - launchDate.getTime();
    const diffSec = Math.floor(diffMs / 1000);
    
    const days = Math.floor(diffSec / 86400);
    const hours = Math.floor((diffSec % 86400) / 3600);
    const minutes = Math.floor((diffSec % 3600) / 60);
    
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  };

  useEffect(() => {
    async function loadInitialData() {
      try {
        const regionsList = await apiFetch("/regions");
        setRegions(regionsList);

        const vpcPreviewPromises = regionsList.map(async (region) => {
          try {
            const vpcs = await apiFetch(`/vpcs?region=${region}`);
            return { region, vpcs };
          } catch (err) {
            console.error(`Failed to load VPCs for ${region}:`, err);
            return { region, vpcs: [] };
          }
        });

        const vpcPreviewResults = await Promise.all(vpcPreviewPromises);
        const vpcPreviewsMap: Record<string, VPCPreview[]> = {};
        
        vpcPreviewResults.forEach(({ region, vpcs }) => {
          vpcPreviewsMap[region] = vpcs;
        });

        setVpcPreviews(vpcPreviewsMap);
      } catch (err) {
        console.error("Failed to load regions:", err);
      } finally {
        setLoading(false);
      }
    }
    loadInitialData();
  }, []);

  useEffect(() => {
    const interval = setInterval(() => {
      setTopologyData((prev) => {
        const updated = { ...prev };
        for (const region in updated) {
          updated[region] = {
            ...updated[region],
            VPCs: updated[region].VPCs.map(vpc => ({
              ...vpc,
              Subnets: Object.fromEntries(
                Object.entries(vpc.Subnets).map(([subnetId, subnet]) => [
                  subnetId,
                  {
                    ...subnet,
                    Instances: subnet.Instances.map(inst => ({
                      ...inst,
                      Uptime: calculateUptime(inst.LaunchTime, inst.State)
                    }))
                  }
                ])
              )
            }))
          };
        }
        return updated;
      });
    }, 60000);
    return () => clearInterval(interval);
  }, []);

  const toggleRegion = async (region: string) => {
    if (expandedRegion === region) {
      setExpandedRegion(null);
      return;
    }

    setExpandedRegion(region);

    if (topologyData[region]) {
      return;
    }

    setLoadingRegions(prev => ({ ...prev, [region]: true }));
    try {
      const data: TopologyData = await apiFetch(`/topology?region=${region}`);
      
      const processedData = {
        ...data,
        VPCs: data.VPCs.map(vpc => ({
          ...vpc,
          Subnets: Object.fromEntries(
            Object.entries(vpc.Subnets).map(([subnetId, subnet]) => [
              subnetId,
              {
                ...subnet,
                Instances: subnet.Instances.map(inst => ({
                  ...inst,
                  Uptime: calculateUptime(inst.LaunchTime, inst.State)
                }))
              }
            ])
          )
        }))
      };
      
      setTopologyData(prev => ({ ...prev, [region]: processedData }));
    } catch (err) {
      console.error(`Failed to load topology for ${region}:`, err);
    } finally {
      setLoadingRegions(prev => ({ ...prev, [region]: false }));
    }
  };

  const toggleVPC = (vpcId: string) => {
    setExpandedVPC(expandedVPC === vpcId ? null : vpcId);
  };

  const toggleSubnet = (subnetId: string) => {
    setExpandedSubnet(expandedSubnet === subnetId ? null : subnetId);
  };

  const getStateBadgeColor = (state: string) => {
    switch (state) {
      case "running": return "bg-green-600 text-white";
      case "stopped": return "bg-gray-600 text-white";
      case "stopping": return "bg-orange-600 text-white";
      default: return "bg-muted text-muted-foreground";
    }
  };

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
            {loading && (
              <div className="flex items-center gap-2 p-4">
                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                <span className="text-sm text-muted-foreground">Loading Topology Overview...</span>
              </div>
            )}

            {regions.map((region) => {
              const regionData = topologyData[region];
              const vpcCount = vpcPreviews[region]?.length ?? 0;

              return (
                <div key={region} className="border border-border rounded-lg w-full">
                  <div
                    onClick={() => toggleRegion(region)}
                    className="flex items-center gap-3 p-4 cursor-pointer hover:bg-muted/50 transition-colors"
                  >
                    {expandedRegion === region ? (
                      <ChevronDown className="h-5 w-5 text-primary" />
                    ) : (
                      <ChevronRight className="h-5 w-5 text-muted-foreground" />
                    )}
                    <Globe className="h-5 w-5 text-secondary" />
                    <span className="font-semibold truncate">{region}</span>
                    {loadingRegions[region] ? (
                      <Loader2 className="h-4 w-4 animate-spin text-primary ml-auto" />
                    ) : (
                      <Badge variant="outline" className="ml-auto">{vpcCount} VPCs</Badge>
                    )}
                  </div>

                  {expandedRegion === region && regionData && (
                    <div className="pl-8 pr-4 pb-4 space-y-2">
                      {regionData.VPCs.map((vpc) => {
                        const subnetCount = Object.keys(vpc.Subnets).length;

                        return (
                          <div key={vpc.VpcId} className="border border-border rounded-lg">
                            <div
                              onClick={() => toggleVPC(vpc.VpcId)}
                              className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                            >
                              {expandedVPC === vpc.VpcId ? (
                                <ChevronDown className="h-4 w-4 text-primary" />
                              ) : (
                                <ChevronRight className="h-4 w-4 text-muted-foreground" />
                              )}
                              <Network className="h-4 w-4 text-accent" />
                              <div className="flex-1 truncate">
                                <div className="font-medium truncate">{vpc.Name ?? vpc.VpcId}</div>
                                <div className="text-xs text-muted-foreground truncate">{vpc.VpcId}</div>
                              </div>
                              <Badge variant="outline">{subnetCount} Subnets</Badge>
                            </div>

                            {expandedVPC === vpc.VpcId && (
                              <div className="pl-8 pr-3 pb-3 space-y-2">
                                {Object.values(vpc.Subnets).map((subnet) => (
                                  <div key={subnet.SubnetId} className="border border-border rounded-lg">
                                    <div
                                      onClick={() => toggleSubnet(subnet.SubnetId)}
                                      className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                                    >
                                      {expandedSubnet === subnet.SubnetId ? (
                                        <ChevronDown className="h-4 w-4 text-primary" />
                                      ) : (
                                        <ChevronRight className="h-4 w-4 text-muted-foreground" />
                                      )}
                                      <Database className="h-4 w-4 text-primary" />
                                      <div className="flex-1 truncate">
                                        <div className="font-medium text-sm truncate">
                                          {subnet.Name ?? subnet.SubnetId}
                                        </div>
                                        <div className="text-xs text-muted-foreground truncate">
                                          {subnet.SubnetId} • {subnet.CidrBlock} • Total: {subnet.InstanceCounts.total} • {subnet.InstanceCounts.running} running • {subnet.InstanceCounts.stopped} stopped
                                        </div>
                                      </div>
                                      <Badge variant="default" className="text-xs">
                                        {subnet.AvailableIpAddressCount} IPs
                                      </Badge>
                                    </div>

                                    {expandedSubnet === subnet.SubnetId && (
                                      <div className="pl-8 pr-3 pb-3 space-y-2">
                                        {subnet.Instances.length === 0 ? (
                                          <div className="text-sm text-muted-foreground p-2">No instances</div>
                                        ) : (
                                          subnet.Instances.map((inst) => (
                                            <div
                                              key={inst.InstanceId}
                                              className="flex items-center gap-3 p-2 border rounded hover:bg-muted/30 transition-colors"
                                            >
                                              <Server className="h-4 w-4 text-success" />
                                              <div className="flex-1 truncate">
                                                <div className="text-sm font-medium truncate">{inst.Name}</div>
                                                <div className="text-xs text-muted-foreground truncate">
                                                  {inst.InstanceId} • {inst.PrivateIpAddress} • {inst.PublicIpAddress}
                                                  {inst.LaunchTime && (
                                                    <>
                                                      {" • "}
                                                      <span className="text-xs text-muted-foreground">
                                                        Launched: {new Date(inst.LaunchTime).toLocaleString()}
                                                      </span>
                                                      {" • "}
                                                      <span className="text-xs text-blue-600">
                                                        Uptime: {inst.Uptime}
                                                      </span>
                                                    </>
                                                  )}
                                                </div>
                                              </div>
                                              <Badge className={getStateBadgeColor(inst.State)}>
                                                {inst.State}
                                              </Badge>
                                            </div>
                                          ))
                                        )}
                                      </div>
                                    )}
                                  </div>
                                ))}
                              </div>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              );
            })}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}