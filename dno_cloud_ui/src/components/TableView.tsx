import { useState, useEffect, useMemo } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table,TableBody,TableCell,TableHead,TableHeader,TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Select,SelectContent,SelectItem,SelectTrigger,SelectValue } from "@/components/ui/select";
import { Search, Filter, Loader2 } from "lucide-react";

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

export function TableView() {
  const [regions, setRegions] = useState<string[]>([]);
  const [filterRegion, setFilterRegion] = useState("all");
  const [searchTerm, setSearchTerm] = useState("");
  const [instances, setInstances] = useState<Instance[]>([]);
  const [initialLoading, setInitialLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const apiFetch = (path: string) => fetch(`/api${path}`).then((res) => res.json());

  const fetchInstanceDetails = async (region: string, instanceId: string) => {
    try {
      const data = await apiFetch(
        `/instance_details?region=${region}&instance_id=${instanceId}`
      );
      const nameTag = data.Tags?.find((t: any) => t.Key === "Name");
      return {
        Name: nameTag ? nameTag.Value : null,
        PrivateIpAddress: data.PrivateIpAddress ?? "-",
        PublicIpAddress: data.PublicIpAddress ?? "-",
        State: data.State?.Name ?? "unknown",
        VpcId: data.VpcId ?? "-",
      };
    } catch {
      return {
        Name: null,
        PrivateIpAddress: "-",
        PublicIpAddress: "-",
        State: "unknown",
        VpcId: "-",
      };
    }
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

        const instancesData: Instance[] = [];

        await Promise.all(
          targetRegions.map(async (region) => {
            const rawInstances: any[] = await apiFetch(`/instances?region=${region}`);

            const tempInstances = rawInstances.map((inst) => ({
              InstanceId: inst.InstanceId,
              Name: null,
              InstanceType: inst.InstanceType ?? "-",
              Region: region,
              VpcId: "-",
              PrivateIpAddress: "-",
              PublicIpAddress: "-",
              State: "loading",
            }));
            instancesData.push(...tempInstances);
            setInstances([...instancesData]); 

            const detailedInstances = await Promise.all(
              rawInstances.map(async (inst) => {
                const details = await fetchInstanceDetails(region, inst.InstanceId);
                return {
                  ...tempInstances.find((i) => i.InstanceId === inst.InstanceId),
                  ...details,
                };
              })
            );

            const startIndex = instancesData.findIndex((i) => i.Region === region);
            instancesData.splice(startIndex, tempInstances.length, ...detailedInstances);
            setInstances([...instancesData]);
          })
        );

        setInitialLoading(false);
      } catch (err: any) {
        setError(err.message);
        setInitialLoading(false);
      }
    };

    fetchAllInstances();
  }, [filterRegion]);

  const filteredInstances = useMemo(() => {
    const term = searchTerm.toLowerCase();
    return instances.filter(
      (inst) =>
        inst.Name?.toLowerCase()?.includes(term) ||
        inst.InstanceId.toLowerCase().includes(term) ||
        inst.PrivateIpAddress?.includes(term) ||
        inst.PublicIpAddress?.includes(term) ||
        inst.VpcId?.includes(term)
    );
  }, [instances, searchTerm]);

  const Skeleton = () => (
    <div className="h-3 bg-muted rounded w-full animate-pulse" />
  );

  return (
    <div className="flex-1 overflow-hidden">
      <div className="max-w-7xl mx-auto">
        <Card className="border-border bg-card/50 backdrop-blur-sm">
          <CardHeader className="space-y-4">
            <CardTitle>EC2 Instances</CardTitle>

            <div className="flex gap-4">
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
                  {regions.map((region) => (
                    <SelectItem key={region} value={region}>
                      {region}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </CardHeader>

          <CardContent>
            {initialLoading ? (
              <div className="flex flex-col items-center justify-center py-20 gap-3">
                <Loader2 className="h-6 w-6 animate-spin text-primary" />
                <p className="text-sm text-muted-foreground">
                  Loading EC2 instances…
                </p>
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
                    </TableRow>
                  </TableHeader>

                  <TableBody>
                    {filteredInstances.length > 0 ? (
                      filteredInstances.map((inst) => (
                        <TableRow key={inst.InstanceId} className="h-8 text-xs">
                          <TableCell className="px-2 break-words max-w-[150px]">
                            {inst.State === "loading" ? (
                              <div className="flex items-center gap-2">
                                <Loader2 className="h-4 w-4 animate-spin text-primary" />
                                Loading...
                              </div>
                            ) : inst.Name ?? "null"}
                          </TableCell>

                          <TableCell className="px-2 break-words font-mono max-w-[150px]">
                            {inst.State === "loading" ? <Skeleton /> : inst.InstanceId}
                          </TableCell>

                          <TableCell className="px-2 max-w-[80px]">
                            {inst.State === "loading" ? <Skeleton /> : inst.InstanceType}
                          </TableCell>

                          <TableCell className="px-2 max-w-[80px]">{inst.Region}</TableCell>

                          <TableCell className="px-2 break-words font-mono max-w-[120px]">
                            {inst.State === "loading" ? <Skeleton /> : inst.VpcId}
                          </TableCell>

                          <TableCell className="px-2 break-words font-mono max-w-[120px]">
                            {inst.State === "loading" ? <Skeleton /> : inst.PrivateIpAddress}
                          </TableCell>

                          <TableCell className="px-2 break-words font-mono max-w-[120px]">
                            {inst.State === "loading" ? <Skeleton /> : inst.PublicIpAddress}
                          </TableCell>

                          <TableCell className="px-2">
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
                          </TableCell>
                        </TableRow>
                      ))
                    ) : (
                      <TableRow>
                        <TableCell
                          colSpan={8}
                          className="text-center py-4 text-muted-foreground"
                        >
                          No instances found
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
