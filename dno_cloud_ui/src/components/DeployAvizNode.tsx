import { useState } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { Server, Download } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";

export function DeployAvizNode() {
  const [selectedRegion, setSelectedRegion] = useState("");
  const [selectedVPC, setSelectedVPC] = useState("");
  const { toast } = useToast();

  const handleDeployAvizNode = () => {
    if (!selectedRegion || !selectedVPC) {
      toast({
        title: "Missing configuration",
        description: "Please select region and VPC first",
        variant: "destructive",
      });
      return;
    }

    toast({
      title: "Deploying Aviz Cloud Node",
      description: "Starting deployment process... This may take a few minutes",
    });
  };

  // Mock deployed nodes data
  const deployedNodes = [
    {
      id: "i-aviz-001",
      name: "Aviz Cloud Node 1",
      region: "us-east-1",
      vpc: "vpc-001",
      ip: "10.0.1.20",
      status: "Running",
    },
    {
      id: "i-aviz-002",
      name: "Aviz Cloud Node 2",
      region: "us-west-2",
      vpc: "vpc-002",
      ip: "10.1.2.30",
      status: "Running",
    },
  ];

  return (
    <div className="space-y-6">
      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Server className="h-5 w-5 text-accent" />
            Deploy Aviz Cloud Node
          </CardTitle>
          <CardDescription>
            Deploy Aviz Cloud Node EC2 instance to receive mirrored traffic
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="region">Select Region</Label>
              <Select value={selectedRegion} onValueChange={setSelectedRegion}>
                <SelectTrigger id="region">
                  <SelectValue placeholder="Choose a region" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="us-east-1">US East (N. Virginia)</SelectItem>
                  <SelectItem value="us-west-2">US West (Oregon)</SelectItem>
                  <SelectItem value="eu-west-1">EU West (Ireland)</SelectItem>
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="vpc">Select VPC</Label>
              <Select value={selectedVPC} onValueChange={setSelectedVPC}>
                <SelectTrigger id="vpc">
                  <SelectValue placeholder="Choose a VPC" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="vpc-001">Production VPC (vpc-001)</SelectItem>
                  <SelectItem value="vpc-002">Development VPC (vpc-002)</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Instance Configuration</Label>
            <div className="p-3 rounded border border-border bg-muted/20 space-y-2 text-sm">
              <div className="flex justify-between">
                <span className="text-muted-foreground">Instance Type:</span>
                <span className="font-medium">c5n.2xlarge</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">vCPUs:</span>
                <span className="font-medium">8</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Memory:</span>
                <span className="font-medium">21 GB</span>
              </div>
              <div className="flex justify-between">
                <span className="text-muted-foreground">Network:</span>
                <span className="font-medium">Up to 25 Gbps</span>
              </div>
            </div>
          </div>

          <div className="space-y-2">
            <Label>Capabilities</Label>
            <div className="space-y-1">
              {["Flow Management", "Deep Packet Inspection (DPI)", "KPI Analysis", "Real-time Monitoring"].map(
                (capability) => (
                  <div key={capability} className="flex items-center gap-2 text-sm">
                    <div className="h-1.5 w-1.5 rounded-full bg-primary" />
                    <span>{capability}</span>
                  </div>
                )
              )}
            </div>
          </div>

          <Button onClick={handleDeployAvizNode} className="w-full">
            <Download className="h-4 w-4 mr-2" />
            Deploy Aviz Cloud Node
          </Button>
        </CardContent>
      </Card>

      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle>Deployed Aviz Cloud Nodes</CardTitle>
          <CardDescription>List of all deployed Aviz Cloud Nodes across regions</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Instance ID</TableHead>
                <TableHead>Name</TableHead>
                <TableHead>Region</TableHead>
                <TableHead>VPC</TableHead>
                <TableHead>IP Address</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {deployedNodes.map((node) => (
                <TableRow key={node.id}>
                  <TableCell className="font-mono text-sm">{node.id}</TableCell>
                  <TableCell className="font-medium">{node.name}</TableCell>
                  <TableCell>{node.region}</TableCell>
                  <TableCell className="font-mono text-sm">{node.vpc}</TableCell>
                  <TableCell className="font-mono text-sm">{node.ip}</TableCell>
                  <TableCell>
                    <Badge className="bg-success text-background">{node.status}</Badge>
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
