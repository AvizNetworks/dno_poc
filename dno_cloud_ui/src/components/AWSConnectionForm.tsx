import React, { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { KeyRound, User, Eye, EyeOff } from "lucide-react";
import { useToast } from "@/hooks/use-toast";

interface AWSConnectionFormProps {
  onConnect: (credentials: {
    accessKeyId: string;
    secretAccessKey: string;
  }) => void;
}

interface FieldProps {
  id: string;
  label: string;
  icon: React.ReactNode;
  type?: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  rightSlot?: React.ReactNode;
}

const FormField = ({
  id,
  label,
  icon,
  type = "text",
  value,
  onChange,
  placeholder,
  rightSlot,
}: FieldProps) => (
  <div className="space-y-2">
    <Label htmlFor={id}>{label}</Label>
    <div className="relative">
      <div className="absolute left-3 top-3 text-muted-foreground">{icon}</div>
      <Input
        id={id}
        type={type}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className="pl-10 pr-10"
        autoComplete="off"
      />
      {rightSlot && (
        <div className="absolute right-3 top-2.5 cursor-pointer text-muted-foreground">
          {rightSlot}
        </div>
      )}
    </div>
  </div>
);

export const AWSConnectionForm = React.memo(
  ({ onConnect }: AWSConnectionFormProps) => {
    const { toast } = useToast();

    const [form, setForm] = useState({
      accessKeyId: "",
      secretAccessKey: "",
    });

    const [isLoading, setIsLoading] = useState(false);
    const [showSecret, setShowSecret] = useState(false);

    const updateField = (key: string, value: string) => {
      setForm((prev) => ({ ...prev, [key]: value }));
    };

    const simulateAPI = () =>
      new Promise((resolve) => setTimeout(resolve, 1000));

    const handleSubmit = async (e: React.FormEvent) => {
      e.preventDefault();

      if (!form.accessKeyId || !form.secretAccessKey) {
        toast({
          title: "Missing credentials",
          description:
            "Please enter both Access Key ID and Secret Access Key.",
          variant: "destructive",
        });
        return;
      }

      setIsLoading(true);
      await simulateAPI();

      toast({
        title: "Connected to AWS",
        description: "Successfully authenticated with AWS.",
      });

      onConnect(form);
      setIsLoading(false);
    };

    return (
      <div className="flex items-center justify-center min-h-[calc(100vh-4rem)] p-8">
        <Card className="w-full max-w-md border-border bg-card/50 backdrop-blur-sm">
          <CardHeader>
            <CardTitle className="text-2xl">Connect to AWS</CardTitle>
            <CardDescription>
              Enter your AWS credentials to start managing your cloud resources.
            </CardDescription>
          </CardHeader>

          <CardContent>
            <form onSubmit={handleSubmit} className="space-y-4">
              <FormField
                id="accessKeyId"
                label="Access Key ID"
                icon={<User className="h-4 w-4" />}
                value={form.accessKeyId}
                onChange={(v) => updateField("accessKeyId", v)}
                placeholder="AKIAIOSFODNN7EXAMPLE"
              />

              <FormField
                id="secretAccessKey"
                label="Secret Access Key"
                icon={<KeyRound className="h-4 w-4" />}
                value={form.secretAccessKey}
                type={showSecret ? "text" : "password"}
                onChange={(v) => updateField("secretAccessKey", v)}
                placeholder="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
                rightSlot={
                  showSecret ? (
                    <EyeOff
                      className="h-4 w-4"
                      onClick={() => setShowSecret(false)}
                    />
                  ) : (
                    <Eye
                      className="h-4 w-4"
                      onClick={() => setShowSecret(true)}
                    />
                  )
                }
              />

              <Button type="submit" className="w-full" disabled={isLoading}>
                {isLoading ? "Connecting..." : "Connect"}
              </Button>
            </form>
          </CardContent>
        </Card>
      </div>
    );
  }
);
