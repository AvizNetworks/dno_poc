import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Eye, EyeOff, Network, Shield, TrendingUp, Zap, CheckCircle2, AlertTriangle } from "lucide-react";

interface AvizOnboardingProps {
  onGetStarted: () => void;
}

export function AvizOnboarding({ onGetStarted }: AvizOnboardingProps) {
  return (
    <div className="min-h-screen bg-background overflow-auto">
      <div className="container mx-auto px-6 py-12 max-w-7xl">
        {/* Hero Section */}
        <div className="text-center mb-16">
          <h1 className="text-4xl font-bold mb-4">
            Why AWS Cloud Visibility Matters
          </h1>
          <p className="text-xl text-muted-foreground max-w-3xl mx-auto">
            Modern cloud workloads are complex, distributed, and constantly evolving. 
            Without proper visibility, you're flying blind.
          </p>
        </div>

        {/* The Problem Section */}
        <div className="mb-16">
          <h2 className="text-3xl font-bold mb-8 text-center">The Challenge</h2>
          <div className="grid md:grid-cols-2 gap-8">
            <Card className="border-destructive/50">
              <CardHeader>
                <div className="flex items-center gap-3 mb-2">
                  <EyeOff className="h-6 w-6 text-destructive" />
                  <CardTitle className="text-xl">Limited Visibility</CardTitle>
                </div>
                <CardDescription>Without proper monitoring tools</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="flex items-start gap-3">
                  <AlertTriangle className="h-5 w-5 text-destructive mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Blind Spots in Traffic Flow</p>
                    <p className="text-sm text-muted-foreground">
                      Cannot see east-west traffic between instances and services
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <AlertTriangle className="h-5 w-5 text-destructive mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Slow Incident Response</p>
                    <p className="text-sm text-muted-foreground">
                      Hours or days to identify root cause of issues
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <AlertTriangle className="h-5 w-5 text-destructive mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Security Vulnerabilities</p>
                    <p className="text-sm text-muted-foreground">
                      Difficult to detect malicious traffic or data exfiltration
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <AlertTriangle className="h-5 w-5 text-destructive mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Compliance Gaps</p>
                    <p className="text-sm text-muted-foreground">
                      Insufficient audit trails for regulatory requirements
                    </p>
                  </div>
                </div>
              </CardContent>
            </Card>

            <Card className="border-primary/50">
              <CardHeader>
                <div className="flex items-center gap-3 mb-2">
                  <Eye className="h-6 w-6 text-primary" />
                  <CardTitle className="text-xl">Complete Visibility</CardTitle>
                </div>
                <CardDescription>With Aviz Cloud Node</CardDescription>
              </CardHeader>
              <CardContent className="space-y-3">
                <div className="flex items-start gap-3">
                  <CheckCircle2 className="h-5 w-5 text-primary mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Full Traffic Visibility</p>
                    <p className="text-sm text-muted-foreground">
                      Mirror and analyze all network traffic in real-time
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <CheckCircle2 className="h-5 w-5 text-primary mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Rapid Troubleshooting</p>
                    <p className="text-sm text-muted-foreground">
                      Minutes to identify and resolve performance issues
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <CheckCircle2 className="h-5 w-5 text-primary mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Enhanced Security</p>
                    <p className="text-sm text-muted-foreground">
                      Deep packet inspection detects threats and anomalies
                    </p>
                  </div>
                </div>
                <div className="flex items-start gap-3">
                  <CheckCircle2 className="h-5 w-5 text-primary mt-0.5 flex-shrink-0" />
                  <div>
                    <p className="font-medium">Compliance Ready</p>
                    <p className="text-sm text-muted-foreground">
                      Comprehensive logging for audits and forensics
                    </p>
                  </div>
                </div>
              </CardContent>
            </Card>
          </div>
        </div>

        {/* Architecture Diagram */}
        <div className="mb-16">
          <h2 className="text-3xl font-bold mb-8 text-center">How Aviz Cloud Node Works</h2>
          <Card>
            <CardContent className="p-8">
              <div className="grid md:grid-cols-3 gap-8">
                {/* Step 1 */}
                <div className="text-center space-y-4">
                  <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
                    <Network className="h-8 w-8 text-primary" />
                  </div>
                  <h3 className="text-xl font-semibold">1. Traffic Mirroring</h3>
                  <p className="text-sm text-muted-foreground">
                    Deploy Aviz Cloud Node in your VPC and configure traffic mirroring 
                    from your EC2 instances to the ACN target
                  </p>
                  <div className="bg-muted/50 rounded-lg p-4 text-left">
                    <p className="text-xs font-mono">
                      AWS VPC → Traffic Mirror<br/>
                      Source: EC2 Instances<br/>
                      Target: Aviz Cloud Node
                    </p>
                  </div>
                </div>

                {/* Step 2 */}
                <div className="text-center space-y-4">
                  <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
                    <Zap className="h-8 w-8 text-primary" />
                  </div>
                  <h3 className="text-xl font-semibold">2. Deep Analysis</h3>
                  <p className="text-sm text-muted-foreground">
                    ACN performs deep packet inspection (DPI) and analyzes traffic patterns, 
                    protocols, and application behaviors in real-time
                  </p>
                  <div className="bg-muted/50 rounded-lg p-4 text-left">
                    <p className="text-xs font-mono">
                      DPI Engine<br/>
                      • Protocol detection<br/>
                      • App classification<br/>
                      • Anomaly detection
                    </p>
                  </div>
                </div>

                {/* Step 3 */}
                <div className="text-center space-y-4">
                  <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
                    <TrendingUp className="h-8 w-8 text-primary" />
                  </div>
                  <h3 className="text-xl font-semibold">3. Actionable Insights</h3>
                  <p className="text-sm text-muted-foreground">
                    Get real-time dashboards, alerts, and reports with predictive 
                    analytics to optimize performance and security
                  </p>
                  <div className="bg-muted/50 rounded-lg p-4 text-left">
                    <p className="text-xs font-mono">
                      Insights Dashboard<br/>
                      • Traffic analytics<br/>
                      • Security alerts<br/>
                      • Cost optimization
                    </p>
                  </div>
                </div>
              </div>

              {/* Flow Arrows */}
              <div className="flex justify-center items-center gap-4 mt-8 text-muted-foreground">
                <div className="flex-1 h-px bg-border"></div>
                <span className="text-sm">Continuous Monitoring Flow</span>
                <div className="flex-1 h-px bg-border"></div>
              </div>
            </CardContent>
          </Card>
        </div>

        {/* Key Benefits */}
        <div className="mb-16">
          <h2 className="text-3xl font-bold mb-8 text-center">Key Benefits</h2>
          <div className="grid md:grid-cols-4 gap-6">
            <Card>
              <CardHeader>
                <Shield className="h-8 w-8 text-primary mb-2" />
                <CardTitle className="text-lg">Security</CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm text-muted-foreground">
                  Detect threats, DDoS attacks, and unauthorized access in real-time
                </p>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <TrendingUp className="h-8 w-8 text-primary mb-2" />
                <CardTitle className="text-lg">Performance</CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm text-muted-foreground">
                  Identify bottlenecks and optimize application performance
                </p>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <Eye className="h-8 w-8 text-primary mb-2" />
                <CardTitle className="text-lg">Visibility</CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm text-muted-foreground">
                  Complete view of north-south and east-west traffic flows
                </p>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CheckCircle2 className="h-8 w-8 text-primary mb-2" />
                <CardTitle className="text-lg">Compliance</CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm text-muted-foreground">
                  Meet regulatory requirements with comprehensive audit trails
                </p>
              </CardContent>
            </Card>
          </div>
        </div>

        {/* CTA Section */}
        <div className="text-center">
          <Card className="border-primary/50 bg-primary/5">
            <CardContent className="py-12">
              <h2 className="text-3xl font-bold mb-4">Ready to Get Started?</h2>
              <p className="text-muted-foreground mb-8 max-w-2xl mx-auto">
                Configure traffic mirroring in minutes and start gaining complete visibility 
                into your AWS workloads with predictive cost analysis and one-click deployment.
              </p>
              <Button size="lg" onClick={onGetStarted} className="text-lg px-8">
                Configure Aviz Cloud Node
              </Button>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}
