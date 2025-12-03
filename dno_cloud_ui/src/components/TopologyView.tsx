import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ChevronDown, ChevronRight, Globe, Network, Server, Database } from "lucide-react";
import { cn } from "@/lib/utils";

interface VPC {
  id: string;
  name: string;
  cidr: string;
}

interface TopologyViewProps {
  regions: string[];
  vpcs: VPC[];
}

export function TopologyView({ regions, vpcs }: TopologyViewProps) {
  const [expandedRegion, setExpandedRegion] = useState<string | null>(regions[0]);
  const [expandedVPC, setExpandedVPC] = useState<string | null>(null);
  const [expandedSubnet, setExpandedSubnet] = useState<string | null>(null);

  // Mock data for demonstration
  const mockSubnets = [
    { id: "subnet-001", name: "Public Subnet 1", cidr: "10.0.1.0/24", type: "public" },
    { id: "subnet-002", name: "Private Subnet 1", cidr: "10.0.2.0/24", type: "private" },
  ];

  const mockInstances = [
    { id: "i-001", name: "Web Server 1", type: "t3.medium", ip: "10.0.1.10", status: "running" },
    { id: "i-002", name: "Web Server 2", type: "t3.medium", ip: "10.0.1.11", status: "running" },
    { id: "i-003", name: "Database Server", type: "r5.large", ip: "10.0.2.10", status: "running" },
  ];

  const toggleRegion = (region: string) => {
    setExpandedRegion(expandedRegion === region ? null : region);
  };

  const toggleVPC = (vpcId: string) => {
    setExpandedVPC(expandedVPC === vpcId ? null : vpcId);
  };

  const toggleSubnet = (subnetId: string) => {
    setExpandedSubnet(expandedSubnet === subnetId ? null : subnetId);
  };

  return (
    <Card className="border-border bg-card/50 backdrop-blur-sm">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Network className="h-5 w-5 text-primary" />
          Network Topology
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {regions.map((region) => (
          <div key={region} className="border border-border rounded-lg overflow-hidden">
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
              <span className="font-semibold">{region}</span>
              <Badge variant="outline" className="ml-auto">
                {vpcs.length} VPCs
              </Badge>
            </div>

            {expandedRegion === region && (
              <div className="pl-8 pr-4 pb-4 space-y-2">
                {vpcs.map((vpc) => (
                  <div key={vpc.id} className="border border-border rounded-lg overflow-hidden">
                    <div
                      onClick={() => toggleVPC(vpc.id)}
                      className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                    >
                      {expandedVPC === vpc.id ? (
                        <ChevronDown className="h-4 w-4 text-primary" />
                      ) : (
                        <ChevronRight className="h-4 w-4 text-muted-foreground" />
                      )}
                      <Network className="h-4 w-4 text-accent" />
                      <div className="flex-1">
                        <div className="font-medium">{vpc.name}</div>
                        <div className="text-xs text-muted-foreground">{vpc.id} • {vpc.cidr}</div>
                      </div>
                      <Badge variant="outline">{mockSubnets.length} Subnets</Badge>
                    </div>

                    {expandedVPC === vpc.id && (
                      <div className="pl-8 pr-3 pb-3 space-y-2">
                        {mockSubnets.map((subnet) => (
                          <div key={subnet.id} className="border border-border rounded-lg overflow-hidden">
                            <div
                              onClick={() => toggleSubnet(subnet.id)}
                              className="flex items-center gap-3 p-3 cursor-pointer hover:bg-muted/50 transition-colors"
                            >
                              {expandedSubnet === subnet.id ? (
                                <ChevronDown className="h-4 w-4 text-primary" />
                              ) : (
                                <ChevronRight className="h-4 w-4 text-muted-foreground" />
                              )}
                              <Database className="h-4 w-4 text-primary" />
                              <div className="flex-1">
                                <div className="font-medium text-sm">{subnet.name}</div>
                                <div className="text-xs text-muted-foreground">{subnet.id} • {subnet.cidr}</div>
                              </div>
                              <Badge 
                                variant={subnet.type === "public" ? "default" : "secondary"}
                                className="text-xs"
                              >
                                {subnet.type}
                              </Badge>
                            </div>

                            {expandedSubnet === subnet.id && (
                              <div className="pl-8 pr-3 pb-3 space-y-1">
                                {mockInstances
                                  .filter((_, idx) => subnet.type === "public" ? idx < 2 : idx === 2)
                                  .map((instance) => (
                                    <div
                                      key={instance.id}
                                      className="flex items-center gap-3 p-2 rounded border border-border hover:bg-muted/30 transition-colors"
                                    >
                                      <Server className="h-4 w-4 text-success" />
                                      <div className="flex-1">
                                        <div className="text-sm font-medium">{instance.name}</div>
                                        <div className="text-xs text-muted-foreground">
                                          {instance.id} • {instance.type} • {instance.ip}
                                        </div>
                                      </div>
                                      <Badge 
                                        className={cn(
                                          "text-xs",
                                          instance.status === "running" && "bg-success text-background"
                                        )}
                                      >
                                        {instance.status}
                                      </Badge>
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
  );
}
