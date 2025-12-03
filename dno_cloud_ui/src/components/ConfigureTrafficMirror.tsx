import { useState } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { Network, Play } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";

export function ConfigureTrafficMirror() {
  const [selectedRegion, setSelectedRegion] = useState("");
  const [selectedVPC, setSelectedVPC] = useState("");
  const [selectedSource, setSelectedSource] = useState("");
  const [selectedTarget, setSelectedTarget] = useState("");
  const { toast } = useToast();

  const handleCreateMirrorSession = () => {
    if (!selectedRegion || !selectedVPC || !selectedSource || !selectedTarget) {
      toast({
        title: "Missing configuration",
        description: "Please select region, VPC, source, and target instances",
        variant: "destructive",
      });
      return;
    }

    toast({
      title: "Traffic mirror session created",
      description: `Successfully created mirror session from ${selectedSource} to ${selectedTarget}`,
    });
  };

  // Mock active sessions data
  const activeSessions = [
    {
      id: "tms-001",
      region: "us-east-1",
      vpc: "vpc-001",
      source: "i-001",
      sourceName: "Web Server 1",
      target: "i-aviz-001",
      targetName: "Aviz Cloud Node 1",
      status: "Active",
    },
    {
      id: "tms-002",
      region: "us-east-1",
      vpc: "vpc-001",
      source: "i-002",
      sourceName: "Web Server 2",
      target: "i-aviz-001",
      targetName: "Aviz Cloud Node 1",
      status: "Active",
    },
  ];

  return (
    <div className="space-y-6">
      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Network className="h-5 w-5 text-primary" />
            Configure Traffic Mirror Session
          </CardTitle>
          <CardDescription>
            Configure AWS Traffic Mirror to send traffic to Aviz Cloud Node
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-4 md:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="mirror-region">Select Region</Label>
              <Select value={selectedRegion} onValueChange={setSelectedRegion}>
                <SelectTrigger id="mirror-region">
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
              <Label htmlFor="mirror-vpc">Select VPC</Label>
              <Select value={selectedVPC} onValueChange={setSelectedVPC}>
                <SelectTrigger id="mirror-vpc">
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
            <Label htmlFor="source">Source Instance</Label>
            <Select value={selectedSource} onValueChange={setSelectedSource}>
              <SelectTrigger id="source">
                <SelectValue placeholder="Choose source instance" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="i-001">Web Server 1 (i-001)</SelectItem>
                <SelectItem value="i-002">Web Server 2 (i-002)</SelectItem>
                <SelectItem value="i-003">Database Server (i-003)</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label htmlFor="target">Target Instance (Aviz Cloud Node)</Label>
            <Select value={selectedTarget} onValueChange={setSelectedTarget}>
              <SelectTrigger id="target">
                <SelectValue placeholder="Choose target instance" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="aviz-001">
                  Aviz Cloud Node 1 (i-aviz-001)
                </SelectItem>
                <SelectItem value="aviz-002">
                  Aviz Cloud Node 2 (i-aviz-002)
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
