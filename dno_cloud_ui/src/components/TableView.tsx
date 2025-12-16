import { useState, useEffect, useMemo } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Search, Filter, Loader2, Play, Square } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";

interface Instance {
  InstanceId: string;
  Name: string | null;
  InstanceType: string;
  State: string;
  PrivateIpAddress?: string;
  PublicIpAddress?: string;
  VpcId?: string;
  Region: string;
}

type StatusFilter = "all" | "running" | "stopped";

export function TableView() {
  const [regions, setRegions] = useState<string[]>([]);
  const [filterRegion, setFilterRegion] = useState("all");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [searchTerm, setSearchTerm] = useState("");
  const [instances, setInstances] = useState<Instance[]>([]);
  const [initialLoading, setInitialLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [stopDialogOpen, setStopDialogOpen] = useState(false);
  const [confirmText, setConfirmText] = useState("");
  const [selectedInstance, setSelectedInstance] = useState<Instance | null>(null);
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  const apiFetch = (path: string) => fetch(`/api${path}`).then((res) => res.json());

  const fetchInstanceDetails = async (region: string, instanceId: string) => {
    try {
      const data = await apiFetch(`/instance_details?region=${region}&instance_id=${instanceId}`);
      const nameTag = data.Tags?.find((t: any) => t.Key === "Name");
      return {
        Name: nameTag ? nameTag.Value : null,
        PrivateIpAddress: data.PrivateIpAddress ?? "-",
        PublicIpAddress: data.PublicIpAddress ?? "-",
        State: data.State?.Name ?? "unknown",
        VpcId: data.VpcId ?? "-",
        InstanceType: data.InstanceType ?? "-",
      };
    } catch {
      return {
        Name: null,
        PrivateIpAddress: "-",
        PublicIpAddress: "-",
        State: "unknown",
        VpcId: "-",
        InstanceType: "-",
      };
    }
  };

  const handleStartInstance = async (instance: Instance) => {
    setActionLoading(instance.InstanceId);
    try {
      await fetch('/api/instances/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ region: instance.Region, instance_ids: [instance.InstanceId] }),
      });

      setInstances(prev => prev.map(inst => inst.InstanceId === instance.InstanceId ? { ...inst, State: 'pending' } : inst));

      let attempts = 0;
      const maxAttempts = 20;
      const pollInterval = setInterval(async () => {
        attempts++;
        try {
          const details = await fetchInstanceDetails(instance.Region, instance.InstanceId);
          setInstances(prev => prev.map(inst => inst.InstanceId === instance.InstanceId ? { ...inst, ...details } : inst));
          if (details.State === 'running' || attempts >= maxAttempts) clearInterval(pollInterval);
        } catch {
          if (attempts >= maxAttempts) clearInterval(pollInterval);
        }
      }, 3000);

    } catch (err) {
      console.error('Failed to start instance:', err);
    } finally {
      setActionLoading(null);
    }
  };

  const handleStopInstance = async () => {
    if (!selectedInstance || confirmText !== 'CONFIRM') return;

    setActionLoading(selectedInstance.InstanceId);
    try {
      await fetch('/api/instances/stop', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ region: selectedInstance.Region, instance_ids: [selectedInstance.InstanceId] }),
      });

      setInstances(prev => prev.map(inst => inst.InstanceId === selectedInstance.InstanceId ? { ...inst, State: 'stopping' } : inst));

      let attempts = 0;
      const maxAttempts = 20;
      const pollInterval = setInterval(async () => {
        attempts++;
        try {
          const details = await fetchInstanceDetails(selectedInstance.Region, selectedInstance.InstanceId);
          setInstances(prev => prev.map(inst => inst.InstanceId === selectedInstance.InstanceId ? { ...inst, ...details } : inst));
          if (details.State === 'stopped' || attempts >= maxAttempts) clearInterval(pollInterval);
        } catch {
          if (attempts >= maxAttempts) clearInterval(pollInterval);
        }
      }, 3000);

    } catch (err) {
      console.error('Failed to stop instance:', err);
    } finally {
      setActionLoading(null);
      setStopDialogOpen(false);
      setConfirmText('');
      setSelectedInstance(null);
    }
  };

  const openStopDialog = (instance: Instance) => {
    setSelectedInstance(instance);
    setStopDialogOpen(true);
  };

  useEffect(() => {
    const fetchAllInstances = async () => {
      setError(null);
      setInstances([]);
      setInitialLoading(true);

      try {
        const allRegions: string[] = await apiFetch("/regions");
        setRegions(allRegions);

        const targetRegions = filterRegion === "all" ? allRegions : [filterRegion];

        const regionInstancesPromises = targetRegions.map(async (region) => {
          const rawInstances: any[] = await apiFetch(`/instances?region=${region}`);
          return rawInstances.map(inst => ({
            InstanceId: inst.InstanceId,
            Name: null,
            InstanceType: inst.InstanceType ?? "-",
            Region: region,
            VpcId: "-",
            PrivateIpAddress: "-",
            PublicIpAddress: "-",
            State: "loading",
          }));
        });

        const allInstancesArrays = await Promise.all(regionInstancesPromises);
        const allInstances = allInstancesArrays.flat();
        setInstances(allInstances);
        setInitialLoading(false);

        const batchSize = 10;
        for (let i = 0; i < allInstances.length; i += batchSize) {
          const batch = allInstances.slice(i, i + batchSize);
          const detailsPromises = batch.map(inst => fetchInstanceDetails(inst.Region, inst.InstanceId).then(details => ({ ...inst, ...details })));
          const batchDetails = await Promise.all(detailsPromises);
          setInstances(prev => {
            const updated = [...prev];
            batchDetails.forEach(detail => {
              const index = updated.findIndex(i => i.InstanceId === detail.InstanceId);
              if (index !== -1) updated[index] = { ...updated[index], ...detail };
            });
            return updated;
          });
        }

      } catch (err: any) {
        setError(err.message);
        setInitialLoading(false);
      }
    };

    fetchAllInstances();
  }, [filterRegion]);

  const filteredInstances = useMemo(() => {
    const term = searchTerm.toLowerCase();
    return instances.filter(inst => {
      const matchesSearch =
        inst.Name?.toLowerCase()?.includes(term) ||
        inst.InstanceId.toLowerCase().includes(term) ||
        inst.PrivateIpAddress?.includes(term) ||
        inst.PublicIpAddress?.includes(term) ||
        inst.VpcId?.includes(term);

      const matchesStatus =
        statusFilter === "all" ? true : inst.State.toLowerCase() === statusFilter;

      return matchesSearch && matchesStatus;
    });
  }, [instances, searchTerm, statusFilter]);

  const getStateBadgeColor = (state: string) => {
    switch (state) {
      case "running": return "bg-green-600 text-white";
      case "pending": return "bg-blue-600 text-white";
      case "stopping": return "bg-orange-600 text-white";
      case "stopped": return "bg-gray-600 text-white";
      default: return "bg-muted text-muted-foreground";
    }
  };

  const Skeleton = () => <div className="h-3 bg-muted rounded w-full animate-pulse" />;

  const statusCounts = useMemo(() => {
    return {
      all: instances.length,
      running: instances.filter(i => i.State === "running").length,
      stopped: instances.filter(i => i.State === "stopped").length,
    };
  }, [instances]);

  return (
    <TooltipProvider>
      <div className="flex-1 overflow-hidden">
        <div className="max-w-7xl mx-auto">
          <Card className="border-border bg-card/50 backdrop-blur-sm">
            <CardHeader className="space-y-4">
              <CardTitle>EC2 Instances</CardTitle>

              <div className="flex flex-col md:flex-row gap-4 md:items-center">
                <div className="relative flex-1">
                  <Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
                  <Input
                    placeholder="Search instances..."
                    value={searchTerm}
                    onChange={(e) => setSearchTerm(e.target.value)}
                    className="pl-10"
                  />
                </div>

                <Select value={filterRegion} onValueChange={setFilterRegion}>
                  <SelectTrigger className="w-48">
                    <Filter className="h-4 w-4 mr-2" />
                    <SelectValue placeholder="Filter by region" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">All Regions</SelectItem>
                    {regions.map(region => <SelectItem key={region} value={region}>{region}</SelectItem>)}
                  </SelectContent>
                </Select>

                <div className="flex items-center gap-1 bg-muted/10 rounded-lg p-1 w-max">
                  {(["all", "running", "stopped"] as StatusFilter[]).map((status) => (
                    <button
                      key={status}
                      className={`
                        relative px-4 py-1 rounded-lg text-sm font-medium transition-all
                        ${statusFilter === status ? "text-primary" : "text-muted-foreground hover:text-primary"}
                      `}
                      onClick={() => setStatusFilter(status)}
                    >
                      {status.charAt(0).toUpperCase() + status.slice(1)}
                      <span className="ml-1 text-xs bg-white/20 rounded-full px-2 py-0.5">
                        {statusCounts[status]}
                      </span>

                      <span
                        className={`
                          absolute -bottom-1 left-0 w-full h-1 rounded-full
                          ${statusFilter === status ? "bg-light-600" : "bg-transparent group-hover:bg-light-500"}
                          transition-all
                        `}
                      ></span>
                    </button>
                  ))}
                </div>

              </div>
            </CardHeader>

            <CardContent>
              {initialLoading ? (
                <div className="flex flex-col items-center justify-center py-20 gap-3">
                  <Loader2 className="h-6 w-6 animate-spin text-primary" />
                  <p className="text-sm text-muted-foreground">Loading EC2 instances…</p>
                </div>
              ) : error ? (
                <p className="text-center text-destructive">{error}</p>
              ) : (
                <div className="rounded-md border border-border overflow-y-auto overflow-x-hidden max-h-[72vh]">
                  <Table className="w-full table-fixed">
                    <TableHeader>
                      <TableRow className="h-8 text-xs">
                        <TableHead className="px-2 max-w-[150px]">Name</TableHead>
                        <TableHead className="px-2 max-w-[150px]">Instance ID</TableHead>
                        <TableHead className="px-2 max-w-[80px]">Type</TableHead>
                        <TableHead className="px-2 max-w-[80px]">Region</TableHead>
                        <TableHead className="px-2 max-w-[120px]">VPC</TableHead>
                        <TableHead className="px-2 max-w-[120px]">Private IP</TableHead>
                        <TableHead className="px-2 max-w-[120px]">Public IP</TableHead>
                        <TableHead className="px-2 max-w-[80px]">Status</TableHead>
                        <TableHead className="px-2 max-w-[100px]">Actions</TableHead>
                      </TableRow>
                    </TableHeader>

                    <TableBody>
                      {filteredInstances.length > 0 ? filteredInstances.map(inst => (
                        <TableRow key={inst.InstanceId} className="h-8 text-xs">
                          <TableCell className="px-2 break-words max-w-[150px]">{inst.State === "loading" ? <Skeleton /> : inst.Name ?? "null"}</TableCell>
                          <TableCell className="px-2 break-words font-mono max-w-[150px]">{inst.State === "loading" ? <Skeleton /> : inst.InstanceId}</TableCell>
                          <TableCell className="px-2 max-w-[80px]">{inst.State === "loading" ? <Skeleton /> : inst.InstanceType}</TableCell>
                          <TableCell className="px-2 max-w-[80px]">{inst.Region}</TableCell>
                          <TableCell className="px-2 break-words font-mono max-w-[120px]">{inst.State === "loading" ? <Skeleton /> : inst.VpcId}</TableCell>
                          <TableCell className="px-2 break-words font-mono max-w-[120px]">{inst.State === "loading" ? <Skeleton /> : inst.PrivateIpAddress}</TableCell>
                          <TableCell className="px-2 break-words font-mono max-w-[120px]">{inst.State === "loading" ? <Skeleton /> : inst.PublicIpAddress}</TableCell>
                          <TableCell className="px-2"><Badge className={getStateBadgeColor(inst.State)}>{inst.State}</Badge></TableCell>
                          <TableCell className="px-2">
                            <div className="flex gap-1">
                              <Tooltip>
                                <TooltipTrigger asChild>
                                  <Button size="sm" variant="ghost" className="h-7 w-7 p-0" disabled={inst.State === "running" || inst.State === "pending" || actionLoading === inst.InstanceId} onClick={() => handleStartInstance(inst)}>
                                    {actionLoading === inst.InstanceId ? <Loader2 className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
                                  </Button>
                                </TooltipTrigger>
                                <TooltipContent>Start Instance</TooltipContent>
                              </Tooltip>
                              <Tooltip>
                                <TooltipTrigger asChild>
                                  <Button size="sm" variant="ghost" className="h-7 w-7 p-0" disabled={inst.State !== "running" || actionLoading === inst.InstanceId} onClick={() => openStopDialog(inst)}>
                                    <Square className="h-4 w-4" />
                                  </Button>
                                </TooltipTrigger>
                                <TooltipContent>Stop Instance</TooltipContent>
                              </Tooltip>
                            </div>
                          </TableCell>
                        </TableRow>
                      )) : (
                        <TableRow>
                          <TableCell colSpan={9} className="text-center py-4 text-muted-foreground">No instances found</TableCell>
                        </TableRow>
                      )}
                    </TableBody>
                  </Table>
                </div>
              )}
            </CardContent>
          </Card>

          <Dialog open={stopDialogOpen} onOpenChange={setStopDialogOpen}>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Stop Instance</DialogTitle>
                <DialogDescription>
                  You are about to stop instance <span className="font-mono font-semibold">{selectedInstance?.InstanceId}</span>{selectedInstance?.Name && ` (${selectedInstance.Name})`}.<br /><br />
                  Type <span className="font-semibold">CONFIRM</span> to confirm.
                </DialogDescription>
              </DialogHeader>
              <Input placeholder="Type CONFIRM to confirm" value={confirmText} onChange={(e) => setConfirmText(e.target.value)} className="mt-2" />
              <DialogFooter>
                <Button variant="outline" onClick={() => { setStopDialogOpen(false); setConfirmText(''); setSelectedInstance(null); }}>Cancel</Button>
                <Button variant="destructive" disabled={confirmText !== 'CONFIRM' || actionLoading !== null} onClick={handleStopInstance}>
                  {actionLoading ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : 'Stop Instance'}
                </Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </div>
      </div>
    </TooltipProvider>
  );
}
