import React from "react";
import { Button } from "@/components/ui/button";
import { Card,CardContent,CardDescription,CardHeader,CardTitle } from "@/components/ui/card";
import {Eye,EyeOff,Network,Shield,TrendingUp,Zap,CheckCircle2,AlertTriangle } from "lucide-react";

interface AvizOnboardingProps {
  onGetStarted: () => void;
}

interface InfoItemProps {
  icon: React.ReactNode;
  title: string;
  description: string;
}
const InfoItem = ({ icon, title, description }: InfoItemProps) => (
  <div className="flex items-start gap-3">
    <div className="mt-0.5 flex-shrink-0">{icon}</div>
    <div>
      <p className="font-medium">{title}</p>
      <p className="text-sm text-muted-foreground">{description}</p>
    </div>
  </div>
);

interface StepProps {
  icon: React.ReactNode;
  step: string;
  title: string;
  description: string;
  code: string[];
}
const Step = ({ icon, step, title, description, code }: StepProps) => (
  <div className="text-center space-y-4">
    <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
      {icon}
    </div>

    <h3 className="text-xl font-semibold">
      {step}. {title}
    </h3>

    <p className="text-sm text-muted-foreground">{description}</p>

    <div className="bg-muted/50 rounded-lg p-4 text-left">
      <p className="text-xs font-mono leading-4">
        {code.map((line, i) => (
          <span key={i}>
            {line}
            <br />
          </span>
        ))}
      </p>
    </div>
  </div>
);

const challenges = [
  {
    title: "Blind Spots in Traffic Flow",
    desc: "Cannot see east-west traffic between instances and services",
  },
  {
    title: "Slow Incident Response",
    desc: "Hours or days to identify root cause of issues",
  },
  {
    title: "Security Vulnerabilities",
    desc: "Difficult to detect malicious traffic or data exfiltration",
  },
  {
    title: "Compliance Gaps",
    desc: "Insufficient audit trails for regulatory requirements",
  },
];

const benefits = [
  {
    icon: <Shield size={32} className="text-primary" />,
    title: "Security",
    desc: "Detect threats, DDoS attacks, and unauthorized access in real-time",
  },
  {
    icon: <TrendingUp size={32} className="text-primary" />,
    title: "Performance",
    desc: "Identify bottlenecks and optimize application performance",
  },
  {
    icon: <Eye size={32} className="text-primary" />,
    title: "Visibility",
    desc: "Complete view of north-south and east-west traffic flows",
  },
  {
    icon: <CheckCircle2 size={32} className="text-primary" />,
    title: "Compliance",
    desc: "Meet regulatory requirements with comprehensive audit trails",
  },
];

const steps = [
  {
    icon: <Network size={32} className="text-primary" />,
    step: "1",
    title: "Traffic Mirroring",
    description:
      "Deploy Virtual Aviz Service Node in your VPC and configure traffic mirroring from your EC2 instances to the ACN target.",
    code: ["AWS VPC → Traffic Mirror", "Source: EC2 Instances", "Target: Virtual Aviz Service Node"],
  },
  {
    icon: <Zap size={32} className="text-primary" />,
    step: "2",
    title: "Deep Analysis",
    description:
      "ACN performs deep packet inspection (DPI) and analyzes traffic patterns, protocols, and application behaviors in real-time.",
    code: [
      "DPI Engine",
      "• Protocol detection",
      "• App classification",
      "• Anomaly detection",
    ],
  },
  {
    icon: <TrendingUp size={32} className="text-primary" />,
    step: "3",
    title: "Actionable Insights",
    description:
      "Get real-time dashboards, alerts, and reports with predictive analytics to optimize performance and security.",
    code: [
      "Insights Dashboard",
      "• Traffic analytics",
      "• Security alerts",
      "• Cost optimization",
    ],
  },
];

export const AvizOnboarding = React.memo(
  ({ onGetStarted }: AvizOnboardingProps) => {
    return (
      <div className="min-h-screen bg-background overflow-auto">
        <div className="container mx-auto px-6 py-12 max-w-7xl">
          <div className="text-center mb-16">
            <h1 className="text-4xl font-bold mb-4">
              Why AWS Cloud Visibility Matters
            </h1>
            <p className="text-xl text-muted-foreground max-w-3xl mx-auto">
              Modern cloud workloads are complex, distributed, and constantly
              evolving. Without proper visibility, you're flying blind.
            </p>
          </div>

          <div className="mb-16">
            <h2 className="text-3xl font-bold mb-8 text-center">The Challenge</h2>

            <div className="grid md:grid-cols-2 gap-8">
              <Card className="border-destructive/50">
                <CardHeader>
                  <div className="flex items-center gap-3 mb-2">
                    <EyeOff size={24} className="text-destructive" />
                    <CardTitle className="text-xl">Limited Visibility</CardTitle>
                  </div>
                  <CardDescription>Without proper monitoring tools</CardDescription>
                </CardHeader>

                <CardContent className="space-y-3">
                  {challenges.map((c, i) => (
                    <InfoItem
                      key={i}
                      icon={<AlertTriangle size={20} className="text-destructive" />}
                      title={c.title}
                      description={c.desc}
                    />
                  ))}
                </CardContent>
              </Card>

              <Card className="border-primary/50">
                <CardHeader>
                  <div className="flex items-center gap-3 mb-2">
                    <Eye size={24} className="text-primary" />
                    <CardTitle className="text-xl">
                      Complete Visibility
                    </CardTitle>
                  </div>
                  <CardDescription>With Virtual Aviz Service Node</CardDescription>
                </CardHeader>

                <CardContent className="space-y-3">
                  {[
                    "Full Traffic Visibility",
                    "Rapid Troubleshooting",
                    "Enhanced Security",
                    "Compliance Ready",
                  ].map((title, i) => (
                    <InfoItem
                      key={i}
                      icon={<CheckCircle2 size={20} className="text-primary" />}
                      title={title}
                      description={
                        [
                          "Mirror and analyze all network traffic in real-time",
                          "Minutes to identify and resolve performance issues",
                          "Deep packet inspection detects threats and anomalies",
                          "Comprehensive logging for audits and forensics",
                        ][i]
                      }
                    />
                  ))}
                </CardContent>
              </Card>
            </div>
          </div>

          <div className="mb-16">
            <h2 className="text-3xl font-bold mb-8 text-center">
              How Virtual Aviz Service Node Works
            </h2>

            <Card>
              <CardContent className="p-8">
                <div className="grid sm:grid-cols-2 md:grid-cols-3 gap-8">
                  {steps.map((s, i) => (
                    <Step key={i} {...s} />
                  ))}
                </div>

                <div className="flex justify-center items-center gap-4 mt-8 text-muted-foreground">
                  <div className="flex-1 h-px bg-border"></div>
                  <span className="text-sm">Continuous Monitoring Flow</span>
                  <div className="flex-1 h-px bg-border"></div>
                </div>
              </CardContent>
            </Card>
          </div>

          <div className="mb-16">
            <h2 className="text-3xl font-bold mb-8 text-center">Key Benefits</h2>

            <div className="grid sm:grid-cols-2 md:grid-cols-4 gap-6">
              {benefits.map((b, i) => (
                <Card key={i}>
                  <CardHeader>
                    {b.icon}
                    <CardTitle className="text-lg">{b.title}</CardTitle>
                  </CardHeader>
                  <CardContent>
                    <p className="text-sm text-muted-foreground">{b.desc}</p>
                  </CardContent>
                </Card>
              ))}
            </div>
          </div>

          <div className="text-center">
            <Card className="border-primary/50 bg-primary/5">
              <CardContent className="py-12">
                <h2 className="text-3xl font-bold mb-4">
                  Ready to Get Started?
                </h2>

                <p className="text-muted-foreground mb-8 max-w-2xl mx-auto">
                  Configure traffic mirroring in minutes and start gaining
                  complete visibility into your AWS workloads with predictive
                  cost analysis and one-click deployment.
                </p>

                <Button size="lg" onClick={onGetStarted} className="text-lg px-8">
                  Configure Virtual Aviz Service Node
                </Button>
              </CardContent>
            </Card>
          </div>
        </div>
      </div>
    );
  }
);
