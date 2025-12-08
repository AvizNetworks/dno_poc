import { Cloud, Server, Database, ChevronRight, ChevronDown } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/utils";
import { Sidebar,SidebarContent,SidebarGroup,SidebarGroupLabel,SidebarMenu,SidebarMenuButton,SidebarMenuItem,SidebarGroupContent } from "@/components/ui/sidebar";

interface CloudProvider {
  id: string;
  name: string;
  icon: typeof Cloud;
  enabled: boolean;
}

const publicClouds: CloudProvider[] = [
  { id: "aws", name: "AWS", icon: Cloud, enabled: true },
  { id: "oci", name: "OCI", icon: Cloud, enabled: false },
  { id: "azure", name: "Azure", icon: Cloud, enabled: false },
  { id: "gcp", name: "GCP", icon: Cloud, enabled: false },
];

const privateClouds: CloudProvider[] = [
  { id: "vmware", name: "VMware", icon: Server, enabled: false },
  { id: "openstack", name: "OpenStack", icon: Database, enabled: false },
];

export function CloudSidebar({
  onProviderSelect,
}: {
  onProviderSelect: (provider: string) => void;
}) {
  const [publicExpanded, setPublicExpanded] = useState(true);
  const [privateExpanded, setPrivateExpanded] = useState(false);
  const [selectedProvider, setSelectedProvider] = useState<string | null>(null);

  const handleProviderClick = (id: string, enabled: boolean) => {
    if (!enabled) return;
    setSelectedProvider(id);
    onProviderSelect(id);
  };

  const renderCloudList = (clouds: CloudProvider[]) => (
    <SidebarGroupContent>
      <SidebarMenu>
        {clouds.map((cloud) => (
          <SidebarMenuItem key={cloud.id}>
            <SidebarMenuButton
              onClick={() => handleProviderClick(cloud.id, cloud.enabled)}
              disabled={!cloud.enabled}
              className={cn(
                "w-full justify-start",
                selectedProvider === cloud.id && "bg-sidebar-accent",
                !cloud.enabled && "opacity-50 cursor-not-allowed"
              )}
            >
              <cloud.icon className="h-4 w-4 mr-2" />
              <span>{cloud.name}</span>
              {!cloud.enabled && (
                <span className="ml-auto text-xs text-muted-foreground">Soon</span>
              )}
            </SidebarMenuButton>
          </SidebarMenuItem>
        ))}
      </SidebarMenu>
    </SidebarGroupContent>
  );

  return (
    <Sidebar className="border-r border-sidebar-border overflow-auto">
      <SidebarContent className="flex flex-col h-full min-h-0">

        <div className="p-4 border-b border-sidebar-border shrink-0">
          <h2 className="text-lg font-semibold bg-gradient-primary bg-clip-text text-transparent">
            Virtual Aviz Cloud Node
          </h2>
        </div>

        <SidebarGroup>
          <SidebarGroupLabel
            onClick={() => setPublicExpanded((prev) => !prev)}
            className="cursor-pointer flex items-center justify-between hover:bg-sidebar-accent transition-colors"
          >
            <span>Public Clouds</span>
            {publicExpanded ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </SidebarGroupLabel>

          {publicExpanded && renderCloudList(publicClouds)}
        </SidebarGroup>

        <SidebarGroup>
          <SidebarGroupLabel
            onClick={() => setPrivateExpanded((prev) => !prev)}
            className="cursor-pointer flex items-center justify-between hover:bg-sidebar-accent transition-colors"
          >
            <span>Private Clouds</span>
            {privateExpanded ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </SidebarGroupLabel>

          {privateExpanded && renderCloudList(privateClouds)}
        </SidebarGroup>
      </SidebarContent>
    </Sidebar>
  );
}
