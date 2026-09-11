import { Link } from 'react-router-dom';
import { PageHeader } from '../components/ui/Card';
import { EmptyState } from '../components/ui/Feedback';
import { Button } from '../components/ui/Button';

export function NotFoundPage(): React.JSX.Element {
  return (
    <>
      <PageHeader title="Page not found" description="The requested route does not exist." />
      <EmptyState
        title="404 — nothing here"
        description="The page you followed may belong to a module that has not been delivered yet. Check the sidebar for what is currently available."
        action={
          <Link to="/">
            <Button variant="secondary">Back to dashboard</Button>
          </Link>
        }
      />
    </>
  );
}
