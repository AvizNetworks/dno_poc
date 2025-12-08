import { useState, useEffect } from "react";
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select,SelectContent,SelectItem,SelectTrigger,SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { Network, Play } from "lucide-react";
import { Table,TableBody,TableCell,TableHead,TableHeader,TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";

export function ConfigureTrafficMirror() {
  const [regions, setRegions] = useState<string[]>([]);
  const [vpcs, setVpcs] = useState<any[]>([]);
  const [subnets, setSubnets] = useState<any[]>([]);
  const [instances, setInstances] = useState<any[]>([]);

  const [selectedRegion, setSelectedRegion] = useState("");
  const [selectedVPC, setSelectedVPC] = useState("");
  const [selectedSource, setSelectedSource] = useState("");
  const [selectedTarget, setSelectedTarget] = useState("");

  const { toast } = useToast();

  const apiFetch = (path: string) =>
    fetch(`/api${path}`).then((res) => res.json());

  useEffect(() => {
    apiFetch("/regions")
      .then((data) => setRegions(data))
      .catch((err) => console.error("Region fetch error:", err));
  }, []);

  useEffect(() => {
    if (!selectedRegion) return;

    setVpcs([]);
    setSubnets([]);
    setInstances([]);
    setSelectedVPC("");
    setSelectedSource("");

    apiFetch(`/vpcs?region=${selectedRegion}`)
      .then((data) => setVpcs(data))
      .catch((err) => console.error("VPC fetch error:", err));
  }, [selectedRegion]);

  useEffect(() => {
    if (!selectedRegion || !selectedVPC) return;

    setSubnets([]);
    setInstances([]);
    setSelectedSource("");

    apiFetch(`/subnets?region=${selectedRegion}&vpc_id=${selectedVPC}`)
      .then((data) => setSubnets(data))
      .catch((err) => console.error("Subnet fetch error:", err));
  }, [selectedRegion, selectedVPC]);

  useEffect(() => {
    if (!selectedRegion || subnets.length === 0) return;

    setInstances([]);
    setSelectedSource("");

    const loadInstances = async () => {
      let allInstances: any[] = [];

      for (const subnet of subnets) {
        try {
          const data = await apiFetch(
            `/instances_in_subnet?region=${selectedRegion}&subnet_id=${subnet.SubnetId}`
          );
          allInstances = [...allInstances, ...data];
        } catch (error) {
          console.error("Instance fetch error:", error);
        }
      }

      setInstances(allInstances);
    };

    loadInstances();
  }, [selectedRegion, subnets]);

  const handleCreateMirrorSession = () => {
    if (!selectedRegion || !selectedVPC || !selectedSource) {
      toast({
        title: "Missing configuration",
        description: "Please select region, VPC, and source instance",
        variant: "destructive",
      });
      return;
    }

    toast({
      title: "Traffic mirror session created",
      description: `Source: ${selectedSource}`,
    });
  };

    const activeSessions = [
    {
      id: "tms-001",
      region: "us-east-1",
      vpc: "vpc-001",
      source: "i-001",
      sourceName: "Web Server 1",
      target: "i-aviz-001",
      targetName: "Virtual Aviz Cloud Node 1",
      status: "Active",
    },
    {
      id: "tms-002",
      region: "us-east-1",
      vpc: "vpc-001",
      source: "i-002",
      sourceName: "Web Server 2",
      target: "i-aviz-001",
      targetName: "Virtual Aviz Cloud Node 1",
      status: "Active",
    },
  ];

  return (
    <div className="space-y-6 overflow-y-auto max-h-screen p-2">
      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Network className="h-5 w-5 text-primary" />
            Configure Traffic Mirror Session
          </CardTitle>
          <CardDescription>
            Configure AWS Traffic Mirror to send traffic to Virtual Aviz Cloud Node
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <Label>Select Region</Label>
              <Select value={selectedRegion} onValueChange={setSelectedRegion}>
                <SelectTrigger>
                  <SelectValue placeholder="Choose region" />
                </SelectTrigger>
                <SelectContent>
                  {regions.map((region) => (
                    <SelectItem key={region} value={region}>
                      {region}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Select VPC</Label>
              <Select
                value={selectedVPC}
                onValueChange={setSelectedVPC}
                disabled={!selectedRegion}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Choose VPC" />
                </SelectTrigger>
                <SelectContent>
                  {vpcs.map((vpc) => (
                    <SelectItem key={vpc.VpcId} value={vpc.VpcId}>
                      {vpc.Name || vpc.VpcId}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Source Instance</Label>
            <Select
              value={selectedSource}
              onValueChange={setSelectedSource}
              disabled={instances.length === 0}
            >
              <SelectTrigger>
                <SelectValue placeholder="Choose source instance" />
              </SelectTrigger>
              <SelectContent>
                {instances.map((inst) => (
                  <SelectItem key={inst.InstanceId} value={inst.InstanceId}>
                    {inst.Name || inst.InstanceId}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="target">Target Instance (Virtual Aviz Cloud Node)</Label>
            <Select value={selectedTarget} onValueChange={setSelectedTarget}>
              <SelectTrigger id="target">
                <SelectValue placeholder="Choose target instance" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="aviz-001">
                  Virtual Aviz Cloud Node 1 (i-aviz-001)
                </SelectItem>
                <SelectItem value="aviz-002">
                  Virtual Aviz Cloud Node 2 (i-aviz-002)
                </SelectItem>
              </SelectContent>
            </Select>
          </div>

          <Button onClick={handleCreateMirrorSession} className="w-full">
            <Play className="h-4 w-4 mr-2" />
            Create Mirror Session
          </Button>
        </CardContent>
      </Card>
      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle>Active Traffic Mirror Sessions</CardTitle>
          <CardDescription>List of all configured traffic mirror sessions</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Session ID</TableHead>
                <TableHead>Region</TableHead>
                <TableHead>VPC</TableHead>
                <TableHead>Source</TableHead>
                <TableHead>Target</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {activeSessions.map((session) => (
                <TableRow key={session.id}>
                  <TableCell className="font-mono text-sm">{session.id}</TableCell>
                  <TableCell>{session.region}</TableCell>
                  <TableCell className="font-mono text-sm">{session.vpc}</TableCell>
                  <TableCell>
                    <div>
                      <div className="font-medium">{session.sourceName}</div>
                      <div className="text-xs text-muted-foreground font-mono">{session.source}</div>
                    </div>
                  </TableCell>
                  <TableCell>
                    <div>
                      <div className="font-medium">{session.targetName}</div>
                      <div className="text-xs text-muted-foreground font-mono">{session.target}</div>
                    </div>
                  </TableCell>
                  <TableCell>
                    <Badge className="bg-success text-background">{session.status}</Badge>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
