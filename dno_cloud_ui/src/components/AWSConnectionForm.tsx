import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { KeyRound, User } from "lucide-react";
import { useToast } from "@/hooks/use-toast";

interface AWSConnectionFormProps {
  onConnect: (credentials: { accessKeyId: string; secretAccessKey: string }) => void;
}

export function AWSConnectionForm({ onConnect }: AWSConnectionFormProps) {
  const [accessKeyId, setAccessKeyId] = useState("");
  const [secretAccessKey, setSecretAccessKey] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const { toast } = useToast();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    
    if (!accessKeyId || !secretAccessKey) {
      toast({
        title: "Missing credentials",
        description: "Please enter both Access Key ID and Secret Access Key",
        variant: "destructive",
      });
      return;
    }

    setIsLoading(true);
    
    // Simulate API call
    setTimeout(() => {
      toast({
        title: "Connected to AWS",
        description: "Successfully authenticated with AWS",
      });
      onConnect({ accessKeyId, secretAccessKey });
      setIsLoading(false);
    }, 1000);
  };

  return (
    <div className="flex items-center justify-center min-h-[calc(100vh-4rem)] p-8">
      <Card className="w-full max-w-md border-border bg-card/50 backdrop-blur-sm">
        <CardHeader>
          <CardTitle className="text-2xl">Connect to AWS</CardTitle>
          <CardDescription>
            Enter your AWS credentials to start managing your cloud resources
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="accessKeyId">Access Key ID</Label>
              <div className="relative">
                <User className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
                <Input
                  id="accessKeyId"
                  type="text"
                  placeholder="AKIAIOSFODNN7EXAMPLE"
                  value={accessKeyId}
                  onChange={(e) => setAccessKeyId(e.target.value)}
                  className="pl-10"
                />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="secretAccessKey">Secret Access Key</Label>
              <div className="relative">
                <KeyRound className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
                <Input
                  id="secretAccessKey"
                  type="password"
                  placeholder="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                  value={secretAccessKey}
                  onChange={(e) => setSecretAccessKey(e.target.value)}
                  className="pl-10"
                />
              </div>
            </div>
            <Button type="submit" className="w-full" disabled={isLoading}>
              {isLoading ? "Connecting..." : "Connect"}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
