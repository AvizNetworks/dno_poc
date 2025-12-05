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
}

export function TopologyView() {
  const [regions, setRegions] = useState<string[]>([]);
  const [vpcs, setVpcs] = useState<Record<string, VPC[]>>({});
  const [subnets, setSubnets] = useState<Record<string, Subnet[]>>({});
  const [instances, setInstances] = useState<Record<string, Instance[]>>({});

  const [expandedRegion, setExpandedRegion] = useState<string | null>(null);
  const [expandedVPC, setExpandedVPC] = useState<string | null>(null);
  const [expandedSubnet, setExpandedSubnet] = useState<string | null>(null);

  const [loading, setLoading] = useState<Record<string, boolean>>({
    regions: true,
  });

  const apiFetch = (path: string) => fetch(`/api${path}`).then((res) => res.json());

  useEffect(() => {
    setLoading((prev) => ({ ...prev, regions: true }));
    apiFetch("/regions")
      .then(setRegions)
      .catch((err) => console.error("Failed to fetch regions:", err))
      .finally(() => setLoading((prev) => ({ ...prev, regions: false })));
  }, []);

  const toggleRegion = async (region: string) => {
    setExpandedRegion(expandedRegion === region ? null : region);
    if (!vpcs[region] && !loading[`region-${region}`]) {
      setLoading((prev) => ({ ...prev, [`region-${region}`]: true }));
      try {
        const data = await apiFetch(`/vpcs?region=${region}`);
        setVpcs((prev) => ({ ...prev, [region]: data }));
      } finally {
        setLoading((prev) => ({ ...prev, [`region-${region}`]: false }));
      }
    }
  };

  const toggleVPC = async (vpcId: string, region: string) => {
    setExpandedVPC(expandedVPC === vpcId ? null : vpcId);
    if (!subnets[vpcId] && !loading[`vpc-${vpcId}`]) {
      setLoading((prev) => ({ ...prev, [`vpc-${vpcId}`]: true }));
      try {
        const data = await apiFetch(`/subnets?region=${region}&vpc_id=${vpcId}`);
        setSubnets((prev) => ({ ...prev, [vpcId]: data }));
      } finally {
        setLoading((prev) => ({ ...prev, [`vpc-${vpcId}`]: false }));
      }
    }
  };

  const fetchInstanceDetails = async (region: string, instanceId: string) => {
    try {
      const data = await apiFetch(
        `/instance_details?region=${region}&instance_id=${instanceId}`
      );
      const nameTag = data.Tags?.find((t: any) => t.Key === "Name");

      return {
        Name: nameTag ? nameTag.Value : instanceId,
        PrivateIpAddress: data.PrivateIpAddress ?? "-",
        PublicIpAddress: data.PublicIpAddress ?? "-",
        State: data.State?.Name?.toLowerCase() ?? "unknown",
      };
    } catch {
      return {
        Name: instanceId,
        PrivateIpAddress: "-",
        PublicIpAddress: "-",
        State: "unknown",
      };
    }
  };

  const toggleSubnet = async (subnetId: string, region: string) => {
    setExpandedSubnet(expandedSubnet === subnetId ? null : subnetId);

    if (!instances[subnetId] && !loading[`subnet-${subnetId}`]) {
      setLoading((prev) => ({ ...prev, [`subnet-${subnetId}`]: true }));

      const data: any[] = await apiFetch(
        `/instances_in_subnet?region=${region}&subnet_id=${subnetId}`
      );

      setInstances((prev) => ({
        ...prev,
        [subnetId]: data.map((inst) => ({
          InstanceId: inst.InstanceId,
          Name: null,
          PrivateIpAddress: "-",
          PublicIpAddress: "-",
          State: "loading",
        })),
      }));

      const detailed = await Promise.all(
        data.map((inst) => fetchInstanceDetails(region, inst.InstanceId))
      );

      setInstances((prev) => ({
        ...prev,
        [subnetId]: data.map((inst, idx) => ({
          InstanceId: inst.InstanceId,
          ...detailed[idx],
        })),
      }));

      setLoading((prev) => ({ ...prev, [`subnet-${subnetId}`]: false }));
    }
  };

  const isLoading = (key: string) => !!loading[key];

  const Skeleton = () => <div className="h-3 w-24 bg-muted rounded animate-pulse" />;

  return (
    <div className="min-h-screen bg-background p-4 sm:p-6 pb-32">
      <div className="container mx-auto max-w-7xl px-2 sm:px-6">
        <Card className="w-full border-border bg-card/50 backdrop-blur-sm">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Network className="h-5 w-5 text-primary" />
              Network Topology
            </CardTitle>
          </CardHeader>

          <CardContent className="space-y-3">

            {loading.regions && (
              <div className="flex items-center gap-2 p-4">
                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                <span className="text-sm text-muted-foreground">
                  Loading Regions...
                </span>
              </div>
            )}

            {regions.map((region) => (
              <div key={region} className="border border-border rounded-lg w-full">
                <div onClick={() => toggleRegion(region)} className="flex items-center gap-3 p-4 cursor-pointer hover:bg-muted/50 transition-colors">
                  {expandedRegion === region ? (
                    <ChevronDown className="h-5 w-5 text-primary" />
                  ) : (
                    <ChevronRight className="h-5 w-5 text-muted-foreground" />
                  )}

                  <Globe className="h-5 w-5 text-secondary" />
                  <span className="font-semibold truncate">{region}</span>

                  {isLoading(`region-${region}`) ? (
                    <Loader2 className="h-4 w-4 ml-auto animate-spin text-primary" />
                  ) : (
                    <Badge variant="outline" className="ml-auto">
                      {vpcs[region]?.length ?? 0} VPCs
                    </Badge>
                  )}
                </div>

                {expandedRegion === region && (
                  <div className="pl-8 pr-4 pb-4 space-y-2">
                    {isLoading(`region-${region}`) && (
                      <div className="flex items-center gap-2">
                        <Loader2 className="h-4 w-4 animate-spin text-primary" />
                        <span>Loading VPCs...</span>
                      </div>
                    )}

                    {vpcs[region]?.map((vpc) => (
                      <div key={vpc.VpcId} className="border border-border rounded-lg">
                    
                        <div onClick={() => toggleVPC(vpc.VpcId, region)} className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors">
                          {expandedVPC === vpc.VpcId ? (
                            <ChevronDown className="h-4 w-4 text-primary" />
                          ) : (
                            <ChevronRight className="h-4 w-4 text-muted-foreground" />
                          )}

                          <Network className="h-4 w-4 text-accent" />

                          <div className="flex-1 truncate">
                            <div className="font-medium truncate">
                              {vpc.Name ?? vpc.VpcId}
                            </div>
                            <div className="text-xs text-muted-foreground truncate">
                              {vpc.VpcId}
                            </div>
                          </div>

                          {isLoading(`vpc-${vpc.VpcId}`) ? (
                            <Loader2 className="h-4 w-4 animate-spin text-primary" />
                          ) : (
                            <Badge variant="outline">
                              {subnets[vpc.VpcId]?.length ?? 0} Subnets
                            </Badge>
                          )}
                        </div>

                        {/* VPC EXPANDED */}
                        {expandedVPC === vpc.VpcId && (
                          <div className="pl-8 pr-3 pb-3 space-y-2">
                            {isLoading(`vpc-${vpc.VpcId}`) && (
                              <div className="flex items-center gap-2">
                                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                                <span>Loading Subnets...</span>
                              </div>
                            )}

                            {subnets[vpc.VpcId]?.map((subnet) => (
                              <div
                                key={subnet.SubnetId}
                                className="border border-border rounded-lg"
                              >
                                <div
                                  onClick={() =>
                                    toggleSubnet(subnet.SubnetId, region)
                                  }
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
                                      {subnet.SubnetId} • {subnet.CidrBlock}
                                    </div>
                                  </div>

                                  <Badge variant="default" className="text-xs">
                                    {subnet.AvailableIpAddressCount} IPs
                                  </Badge>
                                </div>
                                
                                {expandedSubnet === subnet.SubnetId && (
                                  <div className="pl-8 pr-3 pb-3 space-y-2">
                                    {isLoading(
                                      `subnet-${subnet.SubnetId}`
                                    ) && (
                                      <div className="flex items-center gap-2">
                                        <Loader2 className="h-4 w-4 animate-spin text-primary" />
                                        <span>Loading Instances...</span>
                                      </div>
                                    )}

                                    {instances[subnet.SubnetId]?.map(
                                      (inst) => (
                                        <div
                                          key={inst.InstanceId}
                                          className="flex items-center gap-3 p-2 border rounded hover:bg-muted/30 transition-colors"
                                        >
                                          <Server className="h-4 w-4 text-success" />

                                          <div className="flex-1 truncate">
                                            <div className="text-sm font-medium truncate">
                                              {inst.State === "loading" ? (
                                                <Skeleton />
                                              ) : (
                                                inst.Name
                                              )}
                                            </div>

                                            <div className="text-xs text-muted-foreground truncate">
                                              {inst.InstanceId} •{" "}
                                              {inst.PrivateIpAddress} •{" "}
                                              {inst.PublicIpAddress}
                                            </div>
                                          </div>

                                          {inst.State === "loading" ? (
                                            <Skeleton />
                                          ) : (
                                            <Badge
                                              className={
                                                inst.State === "running"
                                                  ? "bg-green-600 text-white"
                                                  : "bg-muted text-muted-foreground"
                                              }
                                            >
                                              {inst.State}
                                            </Badge>
                                          )}
                                        </div>
                                      )
                                    )}
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
