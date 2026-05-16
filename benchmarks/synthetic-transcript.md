Scripta Script
====================
Start: 2026-06-15 12:00:00
End: 2026-06-15 13:00:00

NOTE: This is a SYNTHETIC transcript for benchmarking. Atlas Robotics is a
fictional company. All people, projects, customers, numbers, and decisions
named below are invented. Any resemblance to real entities is coincidental.

Transcript
----------
[12:00:08] Sarah: Alright, can everyone hear me? Great. Welcome to the Atlas Robotics Q2 all-hands.
[12:00:15] Sarah: We've got a packed sixty minutes so I'm going to keep the intro tight.
[12:00:22] Sarah: For folks dialing in, raise hands or drop questions in the chat and we'll get to as many as we can at the end.
[12:00:30] Sarah: Quick agenda. I'll do five minutes on the company. Then Marcus has engineering for about fifteen.
[12:00:38] Sarah: James will take fifteen on product and customers. Lisa has CS and renewals for ten.
[12:00:46] Sarah: I'll wrap with Q3 priorities and an award. Then open Q and A. Sound good? Let's go.
[12:00:55] Sarah: First, the headline. We closed Q2 at four point two million in ARR.
[12:01:03] Sarah: That's against a plan of four flat, so eighteen days of buffer ahead of target. Excellent quarter.
[12:01:12] Sarah: Big thank you to the sales team, especially Diane and Robert, who together closed three of the four new logos.
[12:01:21] Sarah: Second headline. Headcount is now forty seven, up from thirty nine at the end of Q1.
[12:01:29] Sarah: That's eight new teammates in twelve weeks which is a lot of onboarding. I want to thank Priya and Tomás for picking up so much of the mentoring load.
[12:01:39] Sarah: Third. The Cambridge office. We signed the lease two weeks ago.
[12:01:46] Sarah: Move-in is August eleventh. It's a full floor at One Kendall Square, six thousand square feet, room for sixty seats plus a wet lab.
[12:01:56] Sarah: For folks in the Boston area, you'll get an email from facilities next week with the desk picker. Remote teammates, nothing changes for you.
[12:02:05] Sarah: Fourth. As many of you saw last week, Marcus Reyes joined as VP Engineering.
[12:02:13] Sarah: Marcus comes to us from Boston Dynamics where he led the Spot perception team for four years.
[12:02:21] Sarah: Marcus, why don't you say hello and then take it away with the engineering update.
[12:02:28] Marcus: Thanks Sarah. Hi everyone. I've been at Atlas exactly three weeks today.
[12:02:35] Marcus: First impression: this is the most technically deep team for its size I've worked with.
[12:02:43] Marcus: Okay let me dive straight into the engineering update because there's a lot.
[12:02:51] Marcus: Item one. Project Lighthouse. We are still on track for July fifteen.
[12:02:59] Marcus: That's the multi-warehouse pilot with Sevenpoint Logistics. Eight sites going live in one wave.
[12:03:08] Marcus: I know some of you remember when we slipped the original April date, so let me explain why we are confident on July fifteen.
[12:03:18] Marcus: We hit feature freeze last Friday, June twelve. We're now in stabilization with a hard ban on new features.
[12:03:27] Marcus: We have one P0 bug remaining, the gripper miscalibration on second-shift cold starts, and Priya has a fix in review as of yesterday.
[12:03:38] Marcus: If that lands clean by next Wednesday we have a four week stabilization runway which is what the team asked for.
[12:03:47] Marcus: Item two. Performance. The perception pipeline went from twelve frames per second to thirty six frames per second on the same Jetson hardware.
[12:03:58] Marcus: That's three x on the metric we care about most, and it came from two things.
[12:04:07] Marcus: One, Priya rewrote the depth fusion module to use Metal Performance Shaders on the dev rigs and CUDA graphs in production.
[12:04:17] Marcus: Two, we finally retired the legacy point-cloud filter that David and I used to call the slow lane. It is gone.
[12:04:27] Marcus: This means our minimum viable hardware target drops from Jetson AGX Orin to Jetson Orin Nano for the next product line.
[12:04:37] Marcus: That's a roughly four hundred dollar bill of materials reduction per unit. James will say more about pricing implications later.
[12:04:47] Marcus: Item three. Hiring. We brought on five engineers this quarter. Jamie Lopez from MIT in the simulation team.
[12:04:58] Marcus: Priya Sharma, who many of you have met, from Anduril, on perception.
[12:05:06] Marcus: David Kim from Waymo, on motion planning. Anna Kowalski from Mathworks, on developer tools and docs.
[12:05:15] Marcus: And Tomás Reyes, no relation, from Carnegie Mellon RI, on manipulation.
[12:05:23] Marcus: All five have shipped at least one PR to main, which is a record for first-thirty-days at Atlas.
[12:05:32] Marcus: Item four. Tech debt. I promised at my offer stage that I would do a thirty-day audit. I did and there are three things I want to act on.
[12:05:43] Marcus: First, we're deprecating Python three point nine across the codebase. The new floor is three point eleven, with three point twelve allowed.
[12:05:54] Marcus: Deadline for the migration is August twenty second. That gives every service owner ten weeks. Anna has a tracker in Jira.
[12:06:04] Marcus: Second, we're upgrading Kubernetes from one twenty eight to one thirty on all clusters.
[12:06:12] Marcus: Platform team owns the rollout. Staging this Friday, production July first. We expect zero customer impact.
[12:06:21] Marcus: Third, the big one. We are migrating Postgres from fourteen to sixteen by September thirty.
[12:06:30] Marcus: Reason: we need logical replication features that aren't backportable, and Postgres fourteen goes end of life November next year so we're getting ahead.
[12:06:42] Marcus: Anna is leading the migration plan, she'll send a detailed memo by end of next week.
[12:06:50] Marcus: Item five. ROS standardization. We are now on ROS two Humble for all robot deliverables.
[12:06:59] Marcus: The last service still on ROS one Noetic is the simulation farm, and Jamie is porting it. Target completion is end of August.
[12:07:09] Marcus: Item six and last. A tech radar review. I want us to do this every quarter starting next month.
[12:07:18] Marcus: Engineering managers, please send me three candidate technologies to adopt, trial, or retire by June twenty seven.
[12:07:28] Marcus: I'll consolidate and we'll discuss at the engineering offsite July tenth in Boston.
[12:07:37] Marcus: That's engineering. I'll stop there for time. Sarah, back to you for product.
[12:07:46] Sarah: Thanks Marcus. Welcome to the company. James, take it away.
[12:07:53] James: Thanks Sarah. Hey everyone. Three buckets from product side. Customers, roadmap, and pricing.
[12:08:02] James: Customers first. We finished Q2 with twelve enterprise customers, up from nine at the end of Q1.
[12:08:11] James: Three new logos: Boeing Aerospace Manufacturing, Amazon Robotics, and FedEx Ground.
[12:08:20] James: Boeing is a fifty unit deployment for inspection assistance at the Everett facility. Amazon is a thirty unit fulfillment pilot in Stockton.
[12:08:31] James: FedEx is starting with eight units in their Memphis package handling line. Smaller in scope but they are a strategic logo for us.
[12:08:42] James: One loss to mention. We did not win Toyota Manufacturing North America. They went with a Japanese vendor whose name I will not say to avoid jinxing.
[12:08:54] James: The feedback was that we were thirty four percent more expensive on a three-year TCO basis. Hard to compete on price when the alternative is subsidized.
[12:09:06] James: Which brings me to the second topic. Pricing.
[12:09:14] James: Effective September first, we are raising list price by fifteen percent across the SKU set.
[12:09:23] James: That applies to new logos and to renewals on contracts signed after September first.
[12:09:32] James: Existing customers under contract see no change until renewal. Lisa will say more on how that lands with the renewal pipeline.
[12:09:42] James: Why the increase. Three reasons. We have proven enterprise willingness to pay this quarter.
[12:09:52] James: Cost of goods is up nine percent year over year, mostly on Jetson hardware and rare earth magnets.
[12:10:02] James: And finally we want to fund a deeper investment in customer success which Lisa will detail.
[12:10:11] James: Marcus mentioned the four hundred dollar BOM reduction from the new perception pipeline. That doesn't offset the cost of goods rise but it helps margins on the new product line specifically.
[12:10:23] James: Third topic. Roadmap. Two big features coming. Voice control in Q3, multi-robot coordination in Q4.
[12:10:34] James: Voice control launches with Lighthouse on July fifteen. It's English only at launch, Spanish and Japanese by end of Q3.
[12:10:45] James: It uses an on-device Whisper plus a custom wake word. No audio leaves the robot.
[12:10:54] James: Multi-robot coordination is the bigger lift. That's the Q4 headline feature.
[12:11:03] James: Up to sixteen robots in a coordinated swarm with task allocation handled by a central planner running on a Jetson AGX.
[12:11:14] James: This is the feature Amazon wants for their fulfillment expansion. They are effectively our design partner for it.
[12:11:24] James: Beyond Q4, the two things on the radar are outdoor operation and a cloud teleoperation tier. Both are exploratory.
[12:11:35] James: Customer satisfaction. We ran our second quarterly survey. Eighty nine percent of customers said they would recommend Atlas to a peer.
[12:11:46] James: That's up from seventy four percent in Q1. The single biggest driver of improvement was reduced deployment time.
[12:11:56] James: We took median deployment from sixty one days to twenty nine days. Lisa, you want to add anything on that?
[12:12:07] Lisa: Just a quick add. The twenty nine days number is a median. Three of our newer customers went live in under fourteen days.
[12:12:19] Lisa: That's because we shipped the new deployment quickstart in April. Anna led that. It cut about three weeks out of the typical setup.
[12:12:31] James: Right, thank you. Last item from me, a quick win to share. We were named in the Gartner Cool Vendor list for warehouse robotics, published Monday.
[12:12:43] James: That's the second analyst recognition for us this year. Sales is using it in active deals.
[12:12:53] James: Okay that's product. Lisa, customer success is yours.
[12:13:02] Lisa: Thanks James. I'll be quick because I know we want to leave time for questions.
[12:13:11] Lisa: Headline number one. Renewal rate at the end of Q2 is ninety four percent on dollar value, ninety one percent on logo count.
[12:13:23] Lisa: We had one downgrade and one churn. The downgrade was Henkel, going from twenty units to fifteen as they retire a product line.
[12:13:35] Lisa: The churn was a small one, a four unit deployment at a packaging shop in Ohio. Their parent company was acquired and the new owner standardized on a different platform.
[12:13:48] Lisa: Headline two. NPS is sixty seven for Q2, up from fifty two in Q1, and twenty nine when I joined a year ago.
[12:14:00] Lisa: That puts us above the industry-reported median of forty four for enterprise robotics. We are not yet at world class which is seventy plus.
[12:14:12] Lisa: Headline three. Top issues from the customer health calls. Documentation gaps is number one for the fourth straight quarter.
[12:14:24] Lisa: That's why we are doing a full documentation overhaul. Anna Kowalski owns it.
[12:14:33] Lisa: Anna, can you give the timeline?
[12:14:40] Anna: Sure. The plan is a complete rewrite of the operator manual and a new troubleshooting playbook.
[12:14:51] Anna: Operator manual draft by August fifteen, public by September first.
[12:15:00] Anna: Troubleshooting playbook draft by September fifteen, public by October fifteen.
[12:15:10] Anna: I'm pulling in three SMEs from engineering one day a week, with Marcus's blessing.
[12:15:19] Lisa: Thanks Anna. Issue two from health calls is deployment time. As James noted we cut median in half. We want to get to ten days median by year end.
[12:15:32] Lisa: To do that we are hiring two more solutions engineers. Job descriptions go up Monday, target start dates September first.
[12:15:43] Lisa: If you know good candidates, please send them my way. Referral bonus is doubled until we close both seats.
[12:15:53] Lisa: Last item from CS. Customer Advisory Board. Our second CAB meeting is June eighteenth, three days from now.
[12:16:04] Lisa: Six customers attending in person at our current Boston office, four dialing in. Voice control demo is the centerpiece.
[12:16:15] Lisa: Marcus, James, you're both invited to the dinner the night before. Calendar invites already out.
[12:16:25] Lisa: That's it from me. Sarah back to you.
[12:16:34] Sarah: Thanks Lisa. Five minutes to go. Let me cover three things and then we open it up.
[12:16:44] Sarah: First, Q3 priorities. We have three at the company level.
[12:16:52] Sarah: Priority one, Lighthouse launch on July fifteen. Marcus owns it. This is the most important deliverable of the year for revenue and reputation.
[12:17:04] Sarah: Priority two, EU expansion. We are signing a distribution agreement with KionTech in Germany next month.
[12:17:15] Sarah: They will resell into the DACH region and France. Robert is our point of contact and Margaret from legal is leading the contract review.
[12:17:27] Sarah: Priority three, Series B preparation. I have not said this in an all hands before so this is news.
[12:17:38] Sarah: We are targeting a Series B raise in Q4. Not committed yet. We're meeting with three lead investors over the next eight weeks.
[12:17:49] Sarah: The reason we can do this now is the Q2 numbers and the Lighthouse contract. The reason we should do this now is Marcus's hiring plan needs more capital.
[12:18:01] Sarah: I will share more in the next all hands. Please do not discuss publicly. If you have friends asking, point them at the public job board.
[12:18:13] Sarah: Second thing. Engineer of the Quarter. We are recognizing one engineer who had outsized impact in Q2.
[12:18:24] Sarah: This quarter the engineer of the quarter is Priya Sharma.
[12:18:31] Sarah: Priya. The depth fusion rewrite is the single highest leverage piece of code shipped at Atlas this year.
[12:18:42] Sarah: Without it we don't have the cost reduction, the customer demos don't pop the way they do, and Lighthouse is genuinely at risk.
[12:18:53] Sarah: With it, we have a credible path to a sub three thousand dollar unit cost on the next product line. That's a different company.
[12:19:05] Sarah: Priya, plaque is on your desk. Bonus hits payroll this Friday. Congratulations.
[12:19:14] Priya: Thanks Sarah. Quick credit. David Kim caught two regressions in code review that would have shipped without him. Tomás did the perf regression suite. So it's a team thing.
[12:19:28] Sarah: That's exactly the kind of thing I want to hear. Thanks Priya.
[12:19:36] Sarah: Third thing before Q and A. Action item recap. Anna, can you put these in the all hands recap email by end of day?
[12:19:47] Anna: Yep, on it.
[12:19:51] Sarah: Action items from today. One, Python three nine deprecation, Anna driving, deadline August twenty two.
[12:20:02] Sarah: Two, Postgres fourteen to sixteen migration, Anna driving, deadline September thirty.
[12:20:11] Sarah: Three, K8s one thirty rollout, Platform team, deadline July one.
[12:20:20] Sarah: Four, ROS one Noetic to Humble for sim farm, Jamie owning, deadline end of August.
[12:20:30] Sarah: Five, tech radar candidates submitted to Marcus by June twenty seven.
[12:20:38] Sarah: Six, operator manual rewrite, Anna, draft August fifteen public September one.
[12:20:48] Sarah: Seven, troubleshooting playbook, Anna, draft September fifteen public October fifteen.
[12:20:58] Sarah: Eight, two solutions engineer hires, Lisa, target start September one.
[12:21:08] Sarah: Nine, CAB meeting in person Wednesday June eighteen.
[12:21:14] Sarah: Ten, Lighthouse launch readiness review with leadership team July eight, one week before launch.
[12:21:24] Sarah: Okay. Q and A. We have eight minutes. Hands up or chat. David, you were first.
[12:21:34] David: Hey, thanks. Question on the office. With Cambridge opening in August, what's the RTO expectation for folks already in Boston?
[12:21:46] Sarah: Good question. The expectation is unchanged. Hybrid two days a week minimum for folks within a thirty mile radius of the new office.
[12:21:58] Sarah: Anyone fully remote stays fully remote. If you live more than thirty miles from Kendall Square, no change.
[12:22:08] Sarah: If you live closer and want to discuss with HR for a specific reason, talk to Margaret. We are not changing the policy in this meeting.
[12:22:20] David: Got it, thanks.
[12:22:24] Sarah: Jamie, you had your hand up.
[12:22:30] Jamie: Hi, question on the intern program. Atlas had four interns last summer. Are we doing it again, and is there a conversion path for me?
[12:22:43] Jamie: Apologies, that's selfish. But also asking for a friend on the sim team.
[12:22:51] Sarah: Not selfish at all. Marcus, you want to take this one.
[12:22:58] Marcus: Yeah, two parts. Intern program is on for summer twenty twenty seven. We are bringing in six interns next summer, two on each of perception, planning, and sim.
[12:23:11] Marcus: Conversion path. Generally if your manager wants to convert you and you want to convert, we make it happen. Jamie, your manager has already started that conversation.
[12:23:25] Marcus: I'll let you and Tara talk through the details but the answer is positive.
[12:23:33] Jamie: Wow, okay. Thank you.
[12:23:37] Sarah: Anyone else? Robert, you've been quiet which is unusual.
[12:23:45] Robert: I have one. With the fifteen percent pricing increase, do we expect any deals in active pipeline to fall out?
[12:23:56] James: Short answer no. Long answer, we briefed the top ten deals last week, all of which are quoted at current pricing.
[12:24:08] James: New deals after September first start at new pricing. We do not regrade quoted deals. So zero impact on the in flight pipeline.
[12:24:20] Robert: Perfect, thanks.
[12:24:24] Sarah: One more, Tomás.
[12:24:29] Tomás: Quick one for Marcus. The tech radar exercise. Does that include retiring things, or just adopting new things.
[12:24:39] Marcus: Both. Retire is the most important category in fact. I'd rather we retire two things than adopt five.
[12:24:50] Marcus: Specifically I'd love a frank conversation about whether we still need both Python and Rust in the core stack, or whether we should commit to one for the new components.
[12:25:03] Marcus: That conversation is at the offsite July tenth. Come ready.
[12:25:10] Sarah: Okay we are at time. Thank you everyone. A few quick reminders.
[12:25:19] Sarah: Recording goes out by end of day, transcript and action items in the recap email by Anna.
[12:25:30] Sarah: CAB this Wednesday, Lighthouse readiness July eight, launch July fifteen, offsite July ten in Boston, Cambridge move August eleven.
[12:25:43] Sarah: Engineering offsite I just said is July ten. The Boston regional summer party is July nineteen, save the date in your calendar.
[12:25:55] Sarah: Have a great rest of your day. Thanks for the work everyone. See you in two weeks at the team-level reviews.
