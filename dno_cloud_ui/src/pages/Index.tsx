import { useState } from "react";
import { SidebarProvider } from "@/components/ui/sidebar";
import { CloudSidebar } from "@/components/CloudSidebar";
import { AWSConnectionForm } from "@/components/AWSConnectionForm";
import { AWSDashboard } from "@/components/AWSDashboard";
import { AvizOnboarding } from "@/components/AvizOnboarding";

const Index = () => {
  const [selectedProvider, setSelectedProvider] = useState<string | null>(null);
  const [isConnected, setIsConnected] = useState(false);
  const [showOnboarding, setShowOnboarding] = useState(false);

  const handleProviderSelect = (provider: string) => {
    setSelectedProvider(provider);
    setIsConnected(false);
    setShowOnboarding(false);
  };

  const handleAWSConnect = (credentials: { accessKeyId: string; secretAccessKey: string }) => {
    // In production, this would validate credentials with AWS
    console.log("Connecting with credentials:", credentials);
    setIsConnected(true);
    setShowOnboarding(true);
  };

  const handleGetStarted = () => {
    setShowOnboarding(false);
  };

  return (
    <SidebarProvider>
      <div className="min-h-screen flex w-full">
        <CloudSidebar onProviderSelect={handleProviderSelect} />
        
        <main className="flex-1">
          {!selectedProvider ? (
            <div className="flex items-center justify-center h-screen bg-gradient-mesh">
              <div className="text-center space-y-4 max-w-2xl px-6">
                <h1 className="text-5xl font-bold bg-gradient-primary bg-clip-text text-transparent">
                  Virtual Aviz Service Node
                </h1>
                <p className="text-xl text-muted-foreground">
                  Enterprise-grade cloud visibility and traffic analysis platform
                </p>
                <p className="text-foreground/80">
                  Select a cloud provider from the sidebar to get started with traffic mirroring,
                  deep packet inspection, and comprehensive network monitoring.
                </p>
              </div>
            </div>
          ) : selectedProvider === "aws" && !isConnected ? (
            <AWSConnectionForm onConnect={handleAWSConnect} />
          ) : selectedProvider === "aws" && isConnected && showOnboarding ? (
            <AvizOnboarding onGetStarted={handleGetStarted} />
          ) : selectedProvider === "aws" && isConnected ? (
            <AWSDashboard />
          ) : (
            <div className="flex items-center justify-center h-screen">
              <div className="text-center">
                <h2 className="text-2xl font-semibold mb-2">Coming Soon</h2>
                <p className="text-muted-foreground">
                  Support for {selectedProvider?.toUpperCase()} is currently in development
                </p>
              </div>
            </div>
          )}
        </main>
      </div>
    </SidebarProvider>
  );
};

export default Index;
