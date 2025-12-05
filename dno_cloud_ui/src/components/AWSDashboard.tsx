import { useState } from "react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { TopologyView } from "./TopologyView";
import { TableView } from "./TableView";
import { DeployAvizNode } from "./DeployAvizNode";
import { ConfigureTrafficMirror } from "./ConfigureTrafficMirror";
import { Network, Table, Settings } from "lucide-react";

export function AWSDashboard() {
  const [activeView, setActiveView] = useState("topology");
  const [configView, setConfigView] = useState("deploy");

  const mockRegions = ["us-east-1", "us-west-2", "eu-west-1"];
  const mockVPCs = [
    { id: "vpc-001", name: "Production VPC", cidr: "10.0.0.0/16" },
    { id: "vpc-002", name: "Development VPC", cidr: "10.1.0.0/16" },
  ];

  return (
    <div className="flex-1 overflow-hidden">
      <div className="bg-gradient-mesh h-full">
        <div className="p-6 h-full flex flex-col min-h-0">

          <div className="mb-6 shrink-0">
            <h1 className="text-3xl font-bold mb-2">AWS Infrastructure</h1>
            <p className="text-muted-foreground">
              View and manage your AWS resources, configure traffic mirroring, and deploy Aviz Cloud Nodes
            </p>
          </div>

          <Tabs
            value={activeView}
            onValueChange={setActiveView}
            className="flex-1 flex flex-col min-h-0"
          >
            <TabsList className="grid w-full max-w-md grid-cols-3 mb-6">
              <TabsTrigger value="topology" className="flex items-center gap-2">
                <Network className="h-4 w-4" /> Topology
              </TabsTrigger>
              <TabsTrigger value="table" className="flex items-center gap-2">
                <Table className="h-4 w-4" /> Table View
              </TabsTrigger>
              <TabsTrigger value="config" className="flex items-center gap-2">
                <Settings className="h-4 w-4" /> Configuration
              </TabsTrigger>
            </TabsList>

            <TabsContent value="topology" className="flex-1 overflow-auto min-h-0">
              <TopologyView regions={mockRegions} vpcs={mockVPCs} />
            </TabsContent>

            <TabsContent value="table" className="flex-1 overflow-auto min-h-0">
              <TableView />
            </TabsContent>

            <TabsContent value="config" className="flex-1 overflow-auto min-h-0">
              <Tabs
                value={configView}
                onValueChange={setConfigView}
                className="flex flex-col flex-1 min-h-0"
              >
                <TabsList className="grid w-full max-w-md grid-cols-2 mb-4">
                  <TabsTrigger value="deploy">Deploy vACN</TabsTrigger>
                  <TabsTrigger value="mirror">Traffic Mirror</TabsTrigger>
                </TabsList>

                <TabsContent value="deploy" className="flex-1 overflow-auto min-h-0">
                  <DeployAvizNode />
                </TabsContent>

                <TabsContent value="mirror" className="flex-1 overflow-auto min-h-0">
                  <ConfigureTrafficMirror />
                </TabsContent>
              </Tabs>
            </TabsContent>
          </Tabs>
        </div>
      </div>
    </div>
  );
}
