import { useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Search, Filter } from "lucide-react";

export function TableView() {
  const [searchTerm, setSearchTerm] = useState("");
  const [filterRegion, setFilterRegion] = useState("all");

  // Mock EC2 instances data
  const instances = [
    {
      id: "i-001",
      name: "Web Server 1",
      region: "us-east-1",
      vpc: "vpc-001",
      subnet: "subnet-001",
      type: "t3.medium",
      ip: "10.0.1.10",
      publicIp: "54.123.45.67",
      status: "running",
    },
    {
      id: "i-002",
      name: "Web Server 2",
      region: "us-east-1",
      vpc: "vpc-001",
      subnet: "subnet-001",
      type: "t3.medium",
      ip: "10.0.1.11",
      publicIp: "54.123.45.68",
      status: "running",
    },
    {
      id: "i-003",
      name: "Database Server",
      region: "us-east-1",
      vpc: "vpc-001",
      subnet: "subnet-002",
      type: "r5.large",
      ip: "10.0.2.10",
      publicIp: "-",
      status: "running",
    },
    {
      id: "i-004",
      name: "App Server",
      region: "us-west-2",
      vpc: "vpc-002",
      subnet: "subnet-003",
      type: "t3.large",
      ip: "10.1.1.10",
      publicIp: "54.223.45.69",
      status: "stopped",
    },
  ];

  const filteredInstances = instances.filter((instance) => {
    const matchesSearch = 
      instance.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      instance.id.toLowerCase().includes(searchTerm.toLowerCase()) ||
      instance.ip.includes(searchTerm);
    
    const matchesRegion = filterRegion === "all" || instance.region === filterRegion;
    
    return matchesSearch && matchesRegion;
  });

  return (
    <Card className="border-border bg-card/50 backdrop-blur-sm">
      <CardHeader>
        <CardTitle>EC2 Instances</CardTitle>
        <div className="flex gap-4 mt-4">
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
              <SelectItem value="us-east-1">us-east-1</SelectItem>
              <SelectItem value="us-west-2">us-west-2</SelectItem>
              <SelectItem value="eu-west-1">eu-west-1</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </CardHeader>
      <CardContent>
        <div className="rounded-md border border-border overflow-hidden">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Instance Name</TableHead>
                <TableHead>Instance ID</TableHead>
                <TableHead>Type</TableHead>
                <TableHead>Region</TableHead>
                <TableHead>VPC</TableHead>
                <TableHead>Private IP</TableHead>
                <TableHead>Public IP</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filteredInstances.length > 0 ? (
                filteredInstances.map((instance) => (
                  <TableRow key={instance.id} className="hover:bg-muted/30">
                    <TableCell className="font-medium">{instance.name}</TableCell>
                    <TableCell className="font-mono text-sm">{instance.id}</TableCell>
                    <TableCell>{instance.type}</TableCell>
                    <TableCell>{instance.region}</TableCell>
                    <TableCell className="font-mono text-sm">{instance.vpc}</TableCell>
                    <TableCell className="font-mono text-sm">{instance.ip}</TableCell>
                    <TableCell className="font-mono text-sm">{instance.publicIp}</TableCell>
                    <TableCell>
                      <Badge 
                        className={
                          instance.status === "running" 
                            ? "bg-success text-background" 
                            : "bg-muted text-muted-foreground"
                        }
                      >
                        {instance.status}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))
              ) : (
                <TableRow>
                  <TableCell colSpan={8} className="text-center text-muted-foreground">
                    No instances found
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      </CardContent>
    </Card>
  );
}
