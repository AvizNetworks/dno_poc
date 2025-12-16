import { useState, useEffect, useMemo, useCallback } from "react";
import {Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select,SelectContent,SelectItem,SelectTrigger,SelectValue } from "@/components/ui/select";
import { useToast } from "@/hooks/use-toast";
import { Network, Play, RefreshCw, Trash2 } from "lucide-react";
import { Table,TableBody,TableCell,TableHead,TableHeader,TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Tooltip, TooltipContent } from "./ui/tooltip";
import { TooltipTrigger } from "@radix-ui/react-tooltip";

type Instance = { InstanceId: string; Name?: string | null };
type VPC = { VpcId: string; Name?: string; CidrBlock?: string };
type Subnet = { SubnetId: string; CidrBlock: string; Name?: string };
type Session = {
  sessionId: string;
  filterId: string;
  filterDescription?: string;
  sourceInstanceId?: string;
  sourceEni?: string;
  targetId?: string;
  sessionNumber?: number;
  rules?: any[];
};

export function ConfigureTrafficMirror() {
  const { toast } = useToast();

  const [selectedRegion, setSelectedRegion] = useState("");
  const [selectedVPC, setSelectedVPC] = useState("");
  const [selectedSource, setSelectedSource] = useState("");
  const [selectedTarget, setSelectedTarget] = useState("");
  const [targetEnis, setTargetEnis] = useState<{ id: string; name: string }[]>([]);
  const [selectedTargetEni, setSelectedTargetEni] = useState("");

  const [regions, setRegions] = useState<string[]>([]);
  const [networkData, setNetworkData] = useState<{
    vpcs: VPC[];
    subnets: Subnet[];
    instances: Instance[];
  }>({ vpcs: [], subnets: [], instances: [] });

  const [sessions, setSessions] = useState<Session[]>([]);
  const [sessionsLoading, setSessionsLoading] = useState(false);
  const [sessionsError, setSessionsError] = useState<string | null>(null);

  const [creating, setCreating] = useState(false);

  const apiFetch = useCallback(
    async (path: string, opts?: RequestInit) => {
      const res = await fetch(`/api${path}`, opts);
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new Error(text || res.statusText);
      }
      const ct = res.headers.get("content-type") || "";
      if (ct.includes("application/json")) return res.json();
      return null;
    },
    []
  );

  useEffect(() => {
    apiFetch("/regions")
      .then((data) => setRegions(data || []))
      .catch((err) =>
        toast({
          title: "Region load error",
          description: String(err),
          variant: "destructive",
        })
      );
  }, [apiFetch, toast]);

  const resetNetworkSelections = () => {
    setNetworkData({ vpcs: [], subnets: [], instances: [] });
    setSelectedVPC("");
    setSelectedSource("");
    setSelectedTarget("");
  };

  useEffect(() => {
    if (!selectedRegion) {
      resetNetworkSelections();
      return;
    }
    resetNetworkSelections();

    apiFetch(`/vpcs?region=${encodeURIComponent(selectedRegion)}`)
      .then((data) =>
        setNetworkData((prev) => ({ ...prev, vpcs: data || [] }))
      )
      .catch((err) => console.error("VPC fetch error:", err));
  }, [selectedRegion, apiFetch]);

  useEffect(() => {
    if (!selectedRegion || !selectedVPC) return;
    setNetworkData((prev) => ({ ...prev, subnets: [], instances: [] }));
    setSelectedSource("");
    setSelectedTarget("");

    apiFetch(
      `/subnets?region=${encodeURIComponent(
        selectedRegion
      )}&vpc_id=${encodeURIComponent(selectedVPC)}`
    )
      .then((data) =>
        setNetworkData((prev) => ({ ...prev, subnets: data || [] }))
      )
      .catch((err) => console.error("Subnet fetch error:", err));
  }, [selectedRegion, selectedVPC, apiFetch]);

  useEffect(() => {
    const { subnets } = networkData;
    if (!selectedRegion || subnets.length === 0) return;
    setNetworkData((prev) => ({ ...prev, instances: [] }));
    setSelectedSource("");
    setSelectedTarget("");

    let mounted = true;
    const loadInstances = async () => {
      let allInstances: Instance[] = [];
      for (const subnet of subnets) {
        try {
          const data = await apiFetch(
            `/instances_in_subnet?region=${encodeURIComponent(
              selectedRegion
            )}&subnet_id=${encodeURIComponent(subnet.SubnetId)}`
          );
          allInstances = [...allInstances, ...(data || [])];
        } catch (err) {
          console.error("Instance fetch error:", err);
        }
      }
      if (mounted) setNetworkData((prev) => ({ ...prev, instances: allInstances }));
    };

    loadInstances();
    return () => {
      mounted = false;
    };
  }, [selectedRegion, networkData.subnets, apiFetch]);

  useEffect(() => {
    if (!selectedRegion || !selectedTarget) {
      setTargetEnis([]);
      setSelectedTargetEni("");
      return;
    }

    const loadEnis = async () => {
      try {
        const data = await apiFetch(
          `/instance_details?region=${encodeURIComponent(selectedRegion)}&instance_id=${encodeURIComponent(selectedTarget)}`
        );
        const enis = (data?.NetworkInterfaces || []).map((eni: any) => ({
          id: eni.NetworkInterfaceId,
          name: eni.Description || "(No Name)"
        }));
        setTargetEnis(enis);
        if (enis.length > 0) setSelectedTargetEni(enis[0].id);
      } catch (err) {
        toast({
          title: "Failed to load ENIs",
          description: String(err),
          variant: "destructive"
        });
        setTargetEnis([]);
        setSelectedTargetEni("");
      }
    };

    loadEnis();
  }, [selectedRegion, selectedTarget, apiFetch, toast]);


  const loadSessions = useCallback(async () => {
    if (!selectedRegion) return;
    setSessionsLoading(true);
    setSessionsError(null);
    try {
      const data = await apiFetch(
        `/filters?region=${encodeURIComponent(selectedRegion)}`
      );
      const flattened: Session[] = [];
      (data || []).forEach((filter: any) => {
        (filter.Sessions || []).forEach((s: any) => {
          flattened.push({
            filterId: filter.FilterId,
            filterDescription: filter.Description,
            sessionId: s.SessionId,
            sourceInstanceId: s.SourceInstanceId,
            sourceEni: s.SourceEni,
            targetId: s.TargetId,
            sessionNumber: s.SessionNumber,
            rules: filter.Rules || [],
          });
        });
      });
      setSessions(flattened);
    } catch (err: any) {
      setSessionsError(String(err));
      toast({
        title: "Failed to load sessions",
        description: String(err),
        variant: "destructive",
      });
    } finally {
      setSessionsLoading(false);
    }
  }, [selectedRegion, apiFetch, toast]);

  useEffect(() => {
    loadSessions();
  }, [selectedRegion, loadSessions]);

  const instanceMap = useMemo(() => {
    const map = new Map<string, string>();
    networkData.instances.forEach((i) => map.set(i.InstanceId, i.Name || i.InstanceId));
    return map;
  }, [networkData.instances]);

  const resolveInstanceName = (id?: string) => (id ? instanceMap.get(id) || id : "");

  const pickVpcCidr = useMemo(() => {
    const vpc = networkData.vpcs.find((v) => v.VpcId === selectedVPC);
    if (vpc?.CidrBlock) return vpc.CidrBlock;
    if (networkData.subnets.length > 0 && networkData.subnets[0].CidrBlock)
      return networkData.subnets[0].CidrBlock;
    return "0.0.0.0/0";
  }, [selectedVPC, networkData]);

  const handleCreateMirrorSession = async () => {
    if (!selectedRegion || !selectedVPC || !selectedSource || !selectedTarget) {
      toast({
        title: "Missing configuration",
        description: "Please select region, VPC, source and target instance",
        variant: "destructive",
      });
      return;
    }

    if (pickVpcCidr === "0.0.0.0/0") {
      toast({
        title: "Using fallback CIDR",
        description: "Couldn't determine VPC CIDR; using 0.0.0.0/0.",
      });
    }

    setCreating(true);
    try {
      const data = await apiFetch("/mirror", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          region: selectedRegion,
          source_instance_id: selectedSource,
          target_instance_id: selectedTarget,
          target_eni: selectedTargetEni || undefined,
        }),
      });

      toast({
        title: "Mirror session created",
        description: `Session #${data.session_number} created.`,
      });
      await loadSessions();
    } catch (err: any) {
      toast({
        title: "Error creating mirror session",
        description: err?.message || String(err),
        variant: "destructive",
      });
    } finally {
      setCreating(false);
    }
  };

  const handleDeleteSession = async (sessionId: string) => {
    if (!selectedRegion) {
      toast({ title: "Region not selected", description: "", variant: "destructive" });
      return;
    }

    if (!confirm(`Delete session ${sessionId}?`)) return;

    try {
      await apiFetch(
        `/filters/${encodeURIComponent(sessionId)}?region=${encodeURIComponent(
          selectedRegion
        )}`,
        { method: "DELETE" }
      );
      toast({
        title: "Session deleted",
        description: `Session ${sessionId} deleted successfully.`,
      });
      await loadSessions();
    } catch (err: any) {
      toast({
        title: "Error deleting session",
        description: err?.message || String(err),
        variant: "destructive",
      });
    }
  };

  const targetOptions = networkData.instances.filter((i) => i.InstanceId !== selectedSource);

  return (
    <div className="space-y-6 overflow-y-auto max-h-screen p-2">
      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Network className="h-5 w-5 text-primary" />
            Configure Traffic Mirror Session
          </CardTitle>
          <CardDescription>
            Configure AWS Traffic Mirror to send traffic to Virtual Aviz Service Node
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
                  {regions.map((r) => (
                    <SelectItem key={r} value={r}>
                      {r}
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
                  {networkData.vpcs.map((vpc) => (
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
              onValueChange={(val) => {
                setSelectedSource(val);
                if (val === selectedTarget) setSelectedTarget("");
              }}
              disabled={networkData.instances.length === 0}
            >
              <SelectTrigger>
                <SelectValue placeholder="Choose source instance" />
              </SelectTrigger>
              <SelectContent>
                {networkData.instances.map((i) => (
                  <SelectItem key={i.InstanceId} value={i.InstanceId}>
                    {i.Name || i.InstanceId}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label>Target Instance (Virtual Aviz Service Node)</Label>
            <Select
              value={selectedTarget}
              onValueChange={setSelectedTarget}
              disabled={targetOptions.length === 0}
            >
              <SelectTrigger>
                <SelectValue placeholder="Choose target instance" />
              </SelectTrigger>
              <SelectContent>
                {targetOptions.map((i) => (
                  <SelectItem key={i.InstanceId} value={i.InstanceId}>
                    {i.Name || i.InstanceId}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-2">
            <Label>Target ENI</Label>
            <Select
              value={selectedTargetEni}
              onValueChange={setSelectedTargetEni}
              disabled={targetEnis.length === 0}
            >
              <SelectTrigger>
                <SelectValue placeholder="Choose target ENI" />
              </SelectTrigger>
              <SelectContent>
                {targetEnis.map((eni) => (
                  <SelectItem key={eni.id} value={eni.id}>
                    {eni.name} ({eni.id})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <Button
            onClick={handleCreateMirrorSession}
            className="w-full"
            disabled={
              creating ||
              !selectedRegion ||
              !selectedVPC ||
              !selectedSource ||
              !selectedTarget
            }
          >
            <Play className="h-4 w-4 mr-2" />
            {creating ? "Creating..." : "Create Mirror Session"}
          </Button>
        </CardContent>
      </Card>

      <Card className="border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <div className="flex items-center justify-between w-full">
            <div>
              <CardTitle>Active Traffic Mirror Sessions</CardTitle>
              <CardDescription>List of all configured traffic mirror sessions</CardDescription>
            </div>
            <Button
              onClick={loadSessions}
              size="sm"
              disabled={!selectedRegion || sessionsLoading}
              className="ml-4"
            >
              <RefreshCw className="h-4 w-4 mr-2" />
              Refresh
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          {sessionsLoading ? (
            <div className="p-4">Loading sessions…</div>
          ) : sessionsError ? (
            <div className="p-4 text-destructive">Error: {sessionsError}</div>
          ) : sessions.length === 0 ? (
            <div className="p-4 text-muted-foreground">No sessions found.</div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Session ID</TableHead>
                  <TableHead>Source</TableHead>
                  <TableHead>Target</TableHead>
                  <TableHead>Session #</TableHead>
                  <TableHead>Filter</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {sessions.map((s) => (
                  <TableRow key={s.sessionId}>
                    <TableCell className="font-mono text-sm">{s.sessionId}</TableCell>
                    <TableCell>
                      <div>
                        <div className="font-medium">
                          {resolveInstanceName(s.sourceInstanceId) || s.sourceInstanceId}
                        </div>
                        <div className="text-xs text-muted-foreground font-mono">
                          {s.sourceEni || s.sourceInstanceId}
                        </div>
                      </div>
                    </TableCell>
                    <TableCell>
                      <div className="font-medium">{s.targetId}</div>
                    </TableCell>
                    <TableCell className="font-mono text-sm">{s.sessionNumber}</TableCell>
                    <TableCell className="font-mono text-sm">{s.filterId}</TableCell>
                    <TableCell>
                      <div className="flex items-center gap-2">
                        <Badge className="bg-success text-background">Active</Badge>
                        <Tooltip>
                          <TooltipTrigger>
                            <Button
                              size="sm"
                              variant="ghost"
                              className="p-1"
                              onClick={() => handleDeleteSession(s.sessionId)}
                            >
                              <Trash2 className="h-4 w-4" />
                            </Button>
                          </TooltipTrigger>
                          <TooltipContent>Delete session</TooltipContent>
                        </Tooltip>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
