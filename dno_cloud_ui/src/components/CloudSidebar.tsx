import React, { useState, useMemo } from "react";
import { Cloud, Server, Database, ChevronRight, ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { Sidebar,SidebarContent,SidebarGroup,SidebarGroupLabel,SidebarMenu,SidebarMenuButton,SidebarMenuItem,SidebarGroupContent } from "@/components/ui/sidebar";

interface CloudProvider {
  id: string;
  name: string;
  icon: React.ComponentType<{ className?: string }>;
  enabled: boolean;
}

const PUBLIC_CLOUDS: CloudProvider[] = [
  { id: "aws", name: "AWS", icon: Cloud, enabled: true },
  { id: "oci", name: "OCI", icon: Cloud, enabled: false },
  { id: "azure", name: "Azure", icon: Cloud, enabled: false },
  { id: "gcp", name: "GCP", icon: Cloud, enabled: false },
];

const PRIVATE_CLOUDS: CloudProvider[] = [
  { id: "vmware", name: "VMware", icon: Server, enabled: false },
  { id: "openstack", name: "OpenStack", icon: Database, enabled: false },
];

interface CloudGroupProps {
  title: string;
  clouds: CloudProvider[];
  expanded: boolean;
  onToggle: () => void;
  selectedProvider: string | null;
  onSelect: (id: string) => void;
}

const CloudGroup: React.FC<CloudGroupProps> = ({
  title,
  clouds,
  expanded,
  onToggle,
  selectedProvider,
  onSelect,
}) => {
  const renderedList = useMemo(
    () =>
      clouds.map((cloud) => (
        <SidebarMenuItem key={cloud.id}>
          <SidebarMenuButton
            onClick={() => cloud.enabled && onSelect(cloud.id)}
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
      )),
    [clouds, selectedProvider, onSelect]
  );

  return (
    <SidebarGroup>
      <SidebarGroupLabel
        onClick={onToggle}
        className="cursor-pointer flex items-center justify-between hover:bg-sidebar-accent transition-colors"
      >
        <span>{title}</span>
        {expanded ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
      </SidebarGroupLabel>

      {expanded && (
        <SidebarGroupContent>
          <SidebarMenu>{renderedList}</SidebarMenu>
        </SidebarGroupContent>
      )}
    </SidebarGroup>
  );
};

export const CloudSidebar: React.FC<{
  onProviderSelect: (provider: string) => void;
}> = React.memo(({ onProviderSelect }) => {
  const [publicExpanded, setPublicExpanded] = useState(true);
  const [privateExpanded, setPrivateExpanded] = useState(false);
  const [selectedProvider, setSelectedProvider] = useState<string | null>(null);

  const handleSelect = (id: string) => {
    setSelectedProvider(id);
    onProviderSelect(id);
  };

  return (
    <Sidebar className="border-r border-sidebar-border overflow-auto">
      <SidebarContent className="flex flex-col h-full min-h-0">
        <div className="p-4 border-b border-sidebar-border shrink-0">
          <h2 className="text-lg font-semibold bg-gradient-primary bg-clip-text text-transparent">
            Virtual Aviz Service Node
          </h2>
        </div>

        <CloudGroup
          title="Public Clouds"
          clouds={PUBLIC_CLOUDS}
          expanded={publicExpanded}
          onToggle={() => setPublicExpanded((prev) => !prev)}
          selectedProvider={selectedProvider}
          onSelect={handleSelect}
        />

        <CloudGroup
          title="Private Clouds"
          clouds={PRIVATE_CLOUDS}
          expanded={privateExpanded}
          onToggle={() => setPrivateExpanded((prev) => !prev)}
          selectedProvider={selectedProvider}
          onSelect={handleSelect}
        />
      </SidebarContent>
    </Sidebar>
  );
});
